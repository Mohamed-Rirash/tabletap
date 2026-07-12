defmodule Tabletap.Catalog do
  @moduledoc """
  Menu categories, items, and daily availability limits (architecture.md
  Data Model, build-plan.md Feature 04).

  Every function takes `%Scope{}` first and is explicitly venue-scoped —
  `Tabletap.Repo`'s automatic `org_id` filter isn't enough on its own,
  since an org can have more than one venue (Pro tier). Never uses
  `skip_org_id: true` (code-standards.md "Tenancy Rules" reserves that
  for `Accounts`/`Tenants`/platform-admin) — the public menu path gets
  its scope from `Tenants.get_venue_by_slug/1` +
  `Tabletap.Repo.put_org_id/1` first, then reads through here exactly
  like an authenticated manager request.
  """

  import Ecto.Query, warn: false

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog.{Category, DailyItemLimit, MenuItem}
  alias Tabletap.Repo
  alias Tabletap.Tenants

  ## Categories

  @doc "A venue's non-archived categories, ordered for display/reorder."
  def list_categories(%Scope{venue: venue}) do
    Repo.all(
      from(c in Category,
        where: c.venue_id == ^venue.id and is_nil(c.archived_at),
        order_by: c.position
      )
    )
  end

  @doc "Creates a category, appended to the end of the venue's list."
  def create_category(%Scope{org: org, venue: venue}, attrs) do
    %Category{
      org_id: org.id,
      venue_id: venue.id,
      position: next_position(Category, dynamic([c], c.venue_id == ^venue.id))
    }
    |> Category.creation_changeset(attrs)
    |> Repo.insert()
  end

  def update_category(%Scope{}, %Category{} = category, attrs) do
    category |> Category.update_changeset(attrs) |> Repo.update()
  end

  @doc "Archives a category — hidden from menus/pickers, intact in history (design-qa.md Q41)."
  def archive_category(%Scope{}, %Category{} = category) do
    category |> Category.archive_changeset() |> Repo.update()
  end

  @doc """
  Resequences a venue's categories to match `ordered_ids` exactly
  (drag-reorder) — one transaction, full resequence rather than
  fractional positions (menus have dozens of rows, not thousands).
  """
  def reorder_categories(%Scope{venue: venue}, ordered_ids) when is_list(ordered_ids) do
    ordered_ids
    |> Enum.with_index()
    |> Enum.reduce(Ecto.Multi.new(), fn {id, index}, multi ->
      Ecto.Multi.update_all(
        multi,
        {:category, id},
        from(c in Category, where: c.id == ^id and c.venue_id == ^venue.id),
        set: [position: index]
      )
    end)
    |> Repo.transaction()
  end

  ## Items

  @doc "The full menu for manager use — every non-archived category with its non-archived items."
  def list_menu(%Scope{venue: venue} = scope) do
    categories = list_categories(scope)

    items =
      Repo.all(
        from(i in MenuItem,
          where: i.venue_id == ^venue.id and is_nil(i.archived_at),
          order_by: i.position
        )
      )
      |> Enum.group_by(& &1.category_id)

    Enum.map(categories, fn category -> {category, Map.get(items, category.id, [])} end)
  end

  def get_item(%Scope{venue: venue}, id) do
    Repo.one(
      from(i in MenuItem,
        where: i.id == ^id and i.venue_id == ^venue.id and is_nil(i.archived_at)
      )
    )
  end

  @doc "Creates an item in `category`, appended to the end of that category's list."
  def create_item(%Scope{org: org, venue: venue}, %Category{} = category, attrs) do
    %MenuItem{
      org_id: org.id,
      venue_id: venue.id,
      category_id: category.id,
      position: next_position(MenuItem, dynamic([i], i.category_id == ^category.id))
    }
    |> MenuItem.creation_changeset(attrs)
    |> Repo.insert()
  end

  def update_item(%Scope{}, %MenuItem{} = item, attrs) do
    item |> MenuItem.update_changeset(attrs) |> Repo.update()
  end

  @doc "Moves an item to a different category in the same venue, appended to its end."
  def move_item_to_category(%Scope{venue: venue}, %MenuItem{} = item, %Category{} = new_category) do
    if item.venue_id == venue.id && new_category.venue_id == venue.id do
      position = next_position(MenuItem, dynamic([i], i.category_id == ^new_category.id))

      item
      |> MenuItem.category_changeset(new_category.id, position)
      |> Repo.update()
    else
      {:error, :not_found}
    end
  end

  @doc "The daily 86-style toggle — resets each business day, independent of `active`."
  def set_availability(%Scope{}, %MenuItem{} = item, available_today)
      when is_boolean(available_today) do
    item |> MenuItem.availability_changeset(available_today) |> Repo.update()
  end

  @doc "Archives an item — hidden from menus/pickers, intact in history (design-qa.md Q41)."
  def archive_item(%Scope{}, %MenuItem{} = item) do
    item |> MenuItem.archive_changeset() |> Repo.update()
  end

  @doc "Resequences a category's items to match `ordered_ids` exactly (drag-reorder)."
  def reorder_items(%Scope{venue: venue}, %Category{} = category, ordered_ids)
      when is_list(ordered_ids) do
    ordered_ids
    |> Enum.with_index()
    |> Enum.reduce(Ecto.Multi.new(), fn {id, index}, multi ->
      Ecto.Multi.update_all(
        multi,
        {:item, id},
        from(i in MenuItem,
          where: i.id == ^id and i.category_id == ^category.id and i.venue_id == ^venue.id
        ),
        set: [position: index]
      )
    end)
    |> Repo.transaction()
  end

  defp next_position(schema, where_clause) do
    max = Repo.one(from(r in schema, where: ^where_clause, select: max(r.position)))
    if max, do: max + 1, else: 0
  end

  ## Daily limits

  @doc """
  All of a venue's limit rows for `date` (default: today), keyed by
  `item_id` — one query for the manager menu view instead of one per item.
  """
  def list_daily_limits(%Scope{venue: venue}, date \\ nil) do
    date = date || Tenants.business_date(venue)

    Repo.all(from(l in DailyItemLimit, where: l.venue_id == ^venue.id and l.date == ^date))
    |> Map.new(&{&1.item_id, &1})
  end

  @doc "Today's limit row for an item, if a manager has set one (no row = unlimited)."
  def get_daily_limit(%Scope{venue: venue}, %MenuItem{} = item, date \\ nil) do
    date = date || Tenants.business_date(venue)
    Repo.one(from(l in DailyItemLimit, where: l.item_id == ^item.id and l.date == ^date))
  end

  @doc "Sets (or updates) an item's limit for `date` (default: today) — upserts on (item_id, date)."
  def set_daily_limit(
        %Scope{org: org, venue: venue} = scope,
        %MenuItem{} = item,
        limit_qty,
        date \\ nil
      ) do
    date = date || Tenants.business_date(venue)

    case get_daily_limit(scope, item, date) do
      nil ->
        %DailyItemLimit{org_id: org.id, venue_id: venue.id, item_id: item.id, date: date}
        |> DailyItemLimit.set_limit_changeset(%{"limit_qty" => limit_qty})
        |> Repo.insert()

      %DailyItemLimit{} = existing ->
        existing
        |> DailyItemLimit.set_limit_changeset(%{"limit_qty" => limit_qty})
        |> Repo.update()
    end
  end

  @doc "Removes an item's limit for `date` (default: today) — item goes back to unlimited."
  def clear_daily_limit(%Scope{} = scope, %MenuItem{} = item, date \\ nil) do
    case get_daily_limit(scope, item, date) do
      nil -> {:ok, nil}
      %DailyItemLimit{} = existing -> Repo.delete(existing)
    end
  end

  ## Public read — guest scope, org/venue resolved from a QR/slug lookup
  ## (Tenants.get_venue_by_slug/1) rather than an authenticated session.

  @doc """
  The venue's live public menu: active, non-archived categories, each
  with its active + available-today + non-archived items — exactly what
  a scanning customer should see right now.
  """
  def list_public_menu(%Scope{venue: venue}) do
    categories =
      Repo.all(
        from(c in Category,
          where: c.venue_id == ^venue.id and c.active == true and is_nil(c.archived_at),
          order_by: c.position
        )
      )

    items =
      Repo.all(
        from(i in MenuItem,
          where:
            i.venue_id == ^venue.id and i.active == true and i.available_today == true and
              is_nil(i.archived_at),
          order_by: i.position
        )
      )
      |> Enum.group_by(& &1.category_id)

    Enum.map(categories, fn category -> {category, Map.get(items, category.id, [])} end)
  end
end

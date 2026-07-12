defmodule Tabletap.Ordering do
  @moduledoc """
  Guest carts (architecture.md "ordering/" context, build-plan.md Feature
  07). Orders, the state machine, and waiter assignment land here in
  later features (08/10) — this module is cart-only for now.

  Every function takes `%Scope{}` first, same as `Catalog`. The public
  customer path builds its scope exactly like `Public.MenuLive` already
  does: `%Scope{org: venue.org, venue: venue, role: :guest}` — there is
  no authenticated user, so `scope.venue` is the sole source of tenant
  identity here (never `skip_org_id: true` — `Ordering` isn't on that
  exception list, code-standards.md "Tenancy Rules").

  Carts are always **live-computed**, never snapshotted — `cart_total/2`
  and `line_total/1` read the menu's *current* price and option deltas on
  every call. Prices only freeze once a cart converts into an order
  (Feature 08).
  """

  import Ecto.Query, warn: false

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Catalog.{DailyItemLimit, MenuItem}
  alias Tabletap.Ordering.{Cart, CartItem, CartItemOption}
  alias Tabletap.Repo

  ## Reading a guest's cart

  @doc """
  The guest's active cart at this venue, items/menu-item/options
  preloaded — `nil` if they haven't added anything yet (no cart row
  exists until the first `add_to_cart/6`, architecture.md "guest_token
  minted on first add"). The caller (the menu/cart LiveView) rebuilds
  from here on every mount, so reconnects and deploys lose nothing
  (design-qa.md Q50).
  """
  def get_active_cart(%Scope{venue: venue}, guest_token) when is_binary(guest_token) do
    Repo.one(
      from(c in Cart,
        where: c.guest_token == ^guest_token and c.venue_id == ^venue.id and c.status == :active,
        preload: [items: ^items_preload_query()]
      )
    )
  end

  def get_active_cart(%Scope{}, nil), do: nil

  defp items_preload_query do
    from(i in CartItem, order_by: i.inserted_at, preload: [:menu_item, options: :group])
  end

  ## Adding

  @doc """
  Adds one line to the guest's cart, creating the cart itself if this is
  their first add at this venue. `option_ids` is validated against the
  item's *currently* attached modifier groups (same structural rules
  `validate_line/2` re-checks later — design-qa.md Q42) before anything
  is written, so a bad selection never reaches the database.

  Returns `{:ok, cart}` (freshly reloaded) or:
  - `{:error, :item_unavailable}` — inactive, unavailable today,
    archived, or today's daily limit is exhausted
  - `{:error, :options_changed}` — a selected option isn't currently
    offered, or a group's min/max isn't satisfied (the same check and
    the same atom `validate_line/2` returns on later revalidation)
  - `{:error, changeset}` — qty/notes validation failure
  """
  def add_to_cart(
        %Scope{org: org, venue: venue} = scope,
        guest_token,
        table_id,
        %MenuItem{} = item,
        option_ids,
        qty,
        notes
      )
      when is_binary(guest_token) and is_list(option_ids) do
    with :ok <- validate_item_orderable(scope, item),
         groups <- Catalog.list_item_modifier_groups(scope, item),
         :ok <- validate_selection(groups, MapSet.new(option_ids)) do
      Ecto.Multi.new()
      |> Ecto.Multi.run(:cart, fn _repo, _changes ->
        find_or_create_cart(org, venue, table_id, guest_token)
      end)
      |> Ecto.Multi.insert(:cart_item, fn %{cart: cart} ->
        %CartItem{org_id: org.id, cart_id: cart.id, menu_item_id: item.id}
        |> CartItem.creation_changeset(%{"qty" => qty, "notes" => notes})
      end)
      |> attach_options(org, option_ids)
      |> Repo.transaction()
      |> case do
        {:ok, _changes} -> {:ok, get_active_cart(scope, guest_token)}
        {:error, :cart, reason, _changes} -> {:error, reason}
        {:error, :cart_item, changeset, _changes} -> {:error, changeset}
      end
    end
  end

  defp attach_options(multi, org, option_ids) do
    Enum.reduce(option_ids, multi, fn option_id, multi ->
      Ecto.Multi.insert(multi, {:cart_item_option, option_id}, fn %{cart_item: cart_item} ->
        %CartItemOption{org_id: org.id, cart_item_id: cart_item.id, option_id: option_id}
        |> CartItemOption.creation_changeset()
      end)
    end)
  end

  defp find_or_create_cart(org, venue, table_id, guest_token) do
    case active_cart_query(venue, guest_token) |> Repo.one() do
      %Cart{} = cart -> {:ok, cart}
      nil -> insert_cart(org, venue, table_id, guest_token)
    end
  end

  defp insert_cart(org, venue, table_id, guest_token) do
    case Cart.new_changeset(org.id, venue.id, table_id, guest_token) |> Repo.insert() do
      {:ok, cart} -> {:ok, cart}
      # Lost a race with a concurrent add-to-cart for the same guest+venue
      # (two tabs, same not-yet-cookied guest_token) — the other insert
      # won; use its row rather than erroring the whole request.
      {:error, _changeset} -> recover_from_race(venue, guest_token)
    end
  end

  defp recover_from_race(venue, guest_token) do
    case active_cart_query(venue, guest_token) |> Repo.one() do
      %Cart{} = cart -> {:ok, cart}
      nil -> {:error, :cart_unavailable}
    end
  end

  defp active_cart_query(venue, guest_token) do
    from(c in Cart,
      where: c.guest_token == ^guest_token and c.venue_id == ^venue.id and c.status == :active
    )
  end

  defp validate_item_orderable(%Scope{} = scope, %MenuItem{} = item) do
    cond do
      item.archived_at || !item.active || !item.available_today -> {:error, :item_unavailable}
      sold_out?(scope, item) -> {:error, :item_unavailable}
      true -> :ok
    end
  end

  defp sold_out?(%Scope{} = scope, %MenuItem{} = item) do
    case Catalog.get_daily_limit(scope, item) do
      nil -> false
      limit -> DailyItemLimit.remaining(limit) <= 0
    end
  end

  ## Editing / removing

  def update_item(%Scope{}, %CartItem{} = cart_item, attrs) do
    cart_item |> CartItem.update_changeset(attrs) |> Repo.update()
  end

  def remove_item(%Scope{}, %CartItem{} = cart_item) do
    Repo.delete(cart_item)
    :ok
  end

  @doc "Dine-in vs takeaway (build-plan.md Feature 07)."
  def set_kind(%Scope{}, %Cart{} = cart, kind) when kind in [:dine_in, :takeaway] do
    cart |> Cart.kind_changeset(kind) |> Repo.update()
  end

  ## Structural validity (design-qa.md Q42) — re-checked live, never cached

  @doc """
  Whether `cart_item`'s selections still satisfy the item's *current*
  modifier rules — a group's min/max/required can change, or a group can
  be detached entirely, after the line was added. `:ok`, or
  `{:error, :item_unavailable}` / `{:error, :options_changed}` (never a
  crash on a structurally stale line — Q42's "please re-add," not a
  mis-configured order).
  """
  def validate_line(%Scope{} = scope, %CartItem{} = cart_item) do
    item = cart_item.menu_item

    case validate_item_orderable(scope, item) do
      :ok ->
        groups = Catalog.list_item_modifier_groups(scope, item)
        selected_ids = cart_item.options |> Enum.map(& &1.id) |> MapSet.new()
        validate_selection(groups, selected_ids)

      error ->
        error
    end
  end

  defp validate_selection(groups, selected_ids) do
    valid_ids =
      groups
      |> Enum.flat_map(& &1.options)
      |> Enum.filter(& &1.active)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    cond do
      not MapSet.subset?(selected_ids, valid_ids) -> {:error, :options_changed}
      unsatisfied_groups(groups, selected_ids) != [] -> {:error, :options_changed}
      true -> :ok
    end
  end

  @doc """
  Which of `groups` don't currently have enough (or have too many)
  selections in `selected_ids` — the item detail sheet uses this to turn
  a group's requirement chip red only after a submit attempt (ui-tokens.md
  "Modifier Sheet"), and it's the same rule `validate_selection/2` (and
  therefore `add_to_cart/7`/`validate_line/2`) enforces server-side.
  """
  def unsatisfied_groups(groups, selected_ids) do
    Enum.reject(groups, &group_satisfied?(&1, selected_ids))
  end

  defp group_satisfied?(group, selected_ids) do
    count =
      group.options
      |> Enum.filter(& &1.active)
      |> Enum.count(&MapSet.member?(selected_ids, &1.id))

    count >= group.min_selections and count <= group.max_selections
  end

  ## Pricing — always live (see moduledoc)

  @doc "One line's total: (item price + selected option deltas) × qty."
  def line_total(%CartItem{} = cart_item) do
    base = cart_item.menu_item.price
    zero = Money.new!(base.currency, 0)
    deltas = Enum.reduce(cart_item.options, zero, &Money.add!(&2, &1.price_delta))
    Money.mult!(Money.add!(base, deltas), cart_item.qty)
  end

  @doc "The cart's live total across its structurally-valid lines only — an invalid line never counts toward what the customer would pay (Q42)."
  def cart_total(%Scope{venue: venue} = scope, %Cart{} = cart) do
    zero = Money.new!(venue.currency, 0)

    cart.items
    |> Enum.filter(&(validate_line(scope, &1) == :ok))
    |> Enum.reduce(zero, &Money.add!(&2, line_total(&1)))
  end
end

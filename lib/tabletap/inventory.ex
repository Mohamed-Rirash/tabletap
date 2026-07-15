defmodule Tabletap.Inventory do
  @moduledoc """
  Ingredients, recipes, and the stock ledger (architecture.md
  "inventory/"; build-plan.md Feature 12). A menu item with no
  recipe lines deducts nothing on serve — the correct behavior for an
  un-reciped item (most venues before they set this up at all), not a
  bug to work around.

  `Ordering` and `Catalog` call this context's public functions only,
  never `Repo.get(Ingredient, ...)` directly (architecture.md "Context
  rule").

  Plan gating (role-features.md: ingredients/recipes are Growth+) is
  deliberately not enforced here — build-plan.md Feature 19 owns
  "Inventory ... nav/routes check `org.plan` via a `Plans` context
  helper," which doesn't exist yet. This context and its UI are fully
  built and usable by any org until that gate lands.
  """

  import Ecto.Query, warn: false

  alias Tabletap.Accounts.Scope
  alias Tabletap.Inventory.{Ingredient, RecipeLine, StockMovement}
  alias Tabletap.Ordering.Order
  alias Tabletap.Repo

  ## Ingredients (build-plan.md Feature 12)

  @doc "Every non-archived ingredient at the scope's venue, ordered by name."
  def list_ingredients(%Scope{venue: venue}) do
    Repo.all(
      from(i in Ingredient,
        where: i.venue_id == ^venue.id and is_nil(i.archived_at),
        order_by: i.name
      )
    )
  end

  def get_ingredient(%Scope{venue: venue}, id) do
    Repo.one(from(i in Ingredient, where: i.id == ^id and i.venue_id == ^venue.id))
  end

  @doc "A fresh ingredient, always starting at `stock_qty: 0` — see `Ingredient`'s moduledoc for why that's not user-settable."
  def create_ingredient(%Scope{org: org, venue: venue}, attrs) do
    %Ingredient{org_id: org.id, venue_id: venue.id}
    |> Ingredient.creation_changeset(attrs)
    |> Repo.insert()
  end

  def update_ingredient(%Scope{}, %Ingredient{} = ingredient, attrs) do
    ingredient |> Ingredient.update_changeset(attrs) |> Repo.update()
  end

  @doc "Archives an ingredient (design-qa.md Q41) — hidden from the recipe editor/restock pickers, intact in every recipe_line/stock_movement FK and report."
  def archive_ingredient(%Scope{}, %Ingredient{} = ingredient) do
    ingredient |> Ingredient.archive_changeset() |> Repo.update()
  end

  ## Recipe lines (build-plan.md Feature 12's recipe editor)

  @doc "A menu item's bill of materials, ingredient preloaded, alphabetical — what `Manager.MenuLive`'s item modal renders."
  def list_recipe_lines(%Scope{}, %Tabletap.Catalog.MenuItem{} = item) do
    Repo.all(
      from(r in RecipeLine,
        where: r.menu_item_id == ^item.id,
        join: i in assoc(r, :ingredient),
        order_by: i.name,
        preload: [ingredient: i]
      )
    )
  end

  @doc "Adds one ingredient to an item's recipe. Attaching the same ingredient twice returns `{:error, changeset}` via the unique constraint (design-qa.md — same discipline as `Catalog.attach_group_to_item/3`)."
  def add_recipe_line(
        %Scope{org: org},
        %Tabletap.Catalog.MenuItem{} = item,
        %Ingredient{} = ingredient,
        qty_per_serving
      ) do
    %RecipeLine{}
    |> RecipeLine.creation_changeset(%{
      org_id: org.id,
      menu_item_id: item.id,
      ingredient_id: ingredient.id,
      qty_per_serving: qty_per_serving
    })
    |> Repo.insert()
  end

  def update_recipe_line_qty(%Scope{}, %RecipeLine{} = recipe_line, qty_per_serving) do
    recipe_line |> RecipeLine.qty_changeset(qty_per_serving) |> Repo.update()
  end

  def remove_recipe_line(%Scope{}, %RecipeLine{} = recipe_line) do
    Repo.delete(recipe_line)
    :ok
  end

  @doc """
  Writes one `stock_movements` `:sale` row per (order line × recipe
  line) and decrements the matching `ingredients.stock_qty` — called
  from `OrderStateMachine.transition/3` inside the same transaction as
  the `served` status write (architecture.md "On served:
  Inventory.deduct_for_order/2 writes stock_movements per recipe line").
  `order.items` must already be preloaded (the state machine always
  preloads before calling this) — this function preloads each item's
  `:modifiers` itself, since that's only ever needed on this one path.

  Each order line contributes its base recipe (`qty_per_serving × qty`)
  plus every chosen modifier's own `ingredient_qty_delta` (build-plan.md
  Feature 12) — "extra cheese" adds on top of the recipe, "no onions"
  subtracts from it, both `× qty`. A line and its modifiers can net to
  zero for a given ingredient (a removal exactly offsetting the recipe's
  own amount) — that ingredient simply doesn't appear in the movements
  written, not a zero-quantity row.

  Idempotency isn't this function's job — the state machine only ever
  calls it on a genuine `_ -> served` transition, and `served` has no
  transition back to itself (`OrderStateMachine.legal?/2`), so it can
  never run twice for the same order.

  Returns `{:ok, :no_recipe}` when nothing in the order — base recipes
  or modifier deltas alike — resolves to any net deduction (every venue,
  before Feature 12 ships, or any order with no reciped items chosen) —
  a correct no-op, not an error.
  """
  def deduct_for_order(%Scope{org: org, venue: venue} = scope, %Order{} = order) do
    order.items
    |> Repo.preload(:modifiers)
    |> Enum.flat_map(&line_deductions(org.id, &1))
    |> merge_by_ingredient()
    |> case do
      [] ->
        {:ok, :no_recipe}

      deductions ->
        movements = write_deductions(scope, order.id, deductions)

        :telemetry.execute([:tabletap, :inventory, :stock_deducted], %{}, %{
          order_id: order.id,
          venue_id: venue.id,
          movement_count: length(movements)
        })

        {:ok, movements}
    end
  end

  defp line_deductions(org_id, order_item) do
    recipe_deltas =
      org_id
      |> recipe_lines_for(order_item.menu_item_id)
      |> Enum.map(fn line ->
        {line.ingredient_id, Decimal.mult(line.qty_per_serving, Decimal.new(order_item.qty))}
      end)

    modifier_deltas =
      Enum.flat_map(order_item.modifiers, &modifier_deduction(org_id, &1, order_item.qty))

    recipe_deltas ++ modifier_deltas
  end

  defp recipe_lines_for(org_id, menu_item_id) do
    Repo.all(
      from(r in RecipeLine, where: r.org_id == ^org_id and r.menu_item_id == ^menu_item_id)
    )
  end

  defp modifier_deduction(org_id, order_item_modifier, qty) do
    case option_ingredient_delta(org_id, order_item_modifier.option_id) do
      {ingredient_id, delta} when not is_nil(ingredient_id) ->
        [{ingredient_id, Decimal.mult(delta, Decimal.new(qty))}]

      _no_stock_effect ->
        []
    end
  end

  defp option_ingredient_delta(org_id, option_id) do
    Repo.one(
      from(o in Tabletap.Catalog.ModifierOption,
        where: o.id == ^option_id and o.org_id == ^org_id,
        select: {o.ingredient_id, o.ingredient_qty_delta}
      )
    )
  end

  # Two lines on the same order (or the same ingredient in two different
  # items' recipes/modifiers) collapse into one movement row per
  # ingredient. A net-zero total (a removal modifier exactly offsetting
  # its own recipe amount) is dropped entirely — not a zero-quantity
  # audit row.
  defp merge_by_ingredient(deductions) do
    deductions
    |> Enum.group_by(fn {ingredient_id, _qty} -> ingredient_id end, fn {_id, qty} -> qty end)
    |> Enum.map(fn {ingredient_id, qtys} ->
      {ingredient_id, Enum.reduce(qtys, &Decimal.add/2)}
    end)
    |> Enum.reject(fn {_id, qty} -> Decimal.equal?(qty, 0) end)
  end

  defp write_deductions(%Scope{org: org, venue: venue}, order_id, deductions) do
    Repo.transaction(fn ->
      Enum.map(deductions, fn {ingredient_id, qty} ->
        deducted = Decimal.negate(qty)

        Repo.update_all(
          from(i in Ingredient, where: i.id == ^ingredient_id),
          inc: [stock_qty: deducted]
        )

        %{
          org_id: org.id,
          venue_id: venue.id,
          ingredient_id: ingredient_id,
          order_id: order_id,
          qty_delta: deducted
        }
        |> StockMovement.deduction_changeset()
        |> Repo.insert!()
      end)
    end)
    |> case do
      {:ok, movements} -> movements
    end
  end
end

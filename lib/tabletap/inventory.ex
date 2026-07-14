defmodule Tabletap.Inventory do
  @moduledoc """
  Ingredient stock levels + the deduction ledger (architecture.md
  "inventory/"). Feature 11 only needs `deduct_for_order/2` to exist and
  be correct against whatever `recipe_lines` happen to be seeded — there
  is no ingredient/recipe management UI yet (`ingredients` CRUD, the
  recipe editor, restock/wastage flows, low-stock alerts are Phase 4,
  build-plan.md Features 12/13). A menu item with no recipe lines
  deducts nothing, which is the correct behavior for an un-reciped item,
  not a bug to work around.

  Modifier ingredient deltas (`modifier_options.ingredient_id`/
  `ingredient_qty_delta`, architecture.md's data model) stay deferred to
  Feature 12 too — same reasoning `Catalog`'s Feature 05 moduledoc gave
  for those exact columns before the `ingredients` table existed at all.

  `Ordering` calls this context's public functions only, never
  `Repo.get(Ingredient, ...)` directly (architecture.md "Context rule").
  """

  import Ecto.Query, warn: false

  alias Tabletap.Accounts.Scope
  alias Tabletap.Inventory.{Ingredient, RecipeLine, StockMovement}
  alias Tabletap.Ordering.Order
  alias Tabletap.Repo

  @doc """
  Writes one `stock_movements` `:sale` row per (order line × recipe
  line) and decrements the matching `ingredients.stock_qty` — called
  from `OrderStateMachine.transition/3` inside the same transaction as
  the `served` status write (architecture.md "On served:
  Inventory.deduct_for_order/2 writes stock_movements per recipe line").
  `order.items` must already be preloaded (the state machine always
  preloads before calling this).

  Idempotency isn't this function's job — the state machine only ever
  calls it on a genuine `_ -> served` transition, and `served` has no
  transition back to itself (`OrderStateMachine.legal?/2`), so it can
  never run twice for the same order.

  Returns `{:ok, :no_recipe}` when nothing in the order has any recipe
  lines yet (every venue, before Feature 12 ships) — a correct no-op,
  not an error.
  """
  def deduct_for_order(%Scope{org: org, venue: venue}, %Order{} = order) do
    order.items
    |> Enum.flat_map(&line_deductions(org.id, &1))
    |> merge_by_ingredient()
    |> case do
      [] ->
        {:ok, :no_recipe}

      deductions ->
        movements = write_deductions(org.id, venue.id, order.id, deductions)

        :telemetry.execute([:tabletap, :inventory, :stock_deducted], %{}, %{
          order_id: order.id,
          venue_id: venue.id,
          movement_count: length(movements)
        })

        {:ok, movements}
    end
  end

  defp line_deductions(org_id, order_item) do
    org_id
    |> recipe_lines_for(order_item.menu_item_id)
    |> Enum.map(fn line ->
      {line.ingredient_id, Decimal.mult(line.qty_per_serving, Decimal.new(order_item.qty))}
    end)
  end

  defp recipe_lines_for(org_id, menu_item_id) do
    Repo.all(
      from(r in RecipeLine, where: r.org_id == ^org_id and r.menu_item_id == ^menu_item_id)
    )
  end

  # Two lines on the same order (or the same ingredient in two different
  # items' recipes) collapse into one movement row per ingredient rather
  # than several tiny ones for the same order.
  defp merge_by_ingredient(deductions) do
    deductions
    |> Enum.group_by(fn {ingredient_id, _qty} -> ingredient_id end, fn {_id, qty} -> qty end)
    |> Enum.map(fn {ingredient_id, qtys} ->
      {ingredient_id, Enum.reduce(qtys, &Decimal.add/2)}
    end)
  end

  defp write_deductions(org_id, venue_id, order_id, deductions) do
    Repo.transaction(fn ->
      Enum.map(deductions, fn {ingredient_id, qty} ->
        deducted = Decimal.negate(qty)

        Repo.update_all(
          from(i in Ingredient, where: i.id == ^ingredient_id),
          inc: [stock_qty: deducted]
        )

        %{
          org_id: org_id,
          venue_id: venue_id,
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

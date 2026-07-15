defmodule Tabletap.Inventory.RecipeLine do
  @moduledoc """
  One ingredient's quantity-per-serving on a menu item's bill of
  materials (architecture.md Data Model; build-plan.md Feature 12's
  recipe editor). Quantity is always in the ingredient's own base unit —
  `Inventory.UnitInput` converts the manager's typed input before this
  changeset ever sees it.

  `org_id`/`menu_item_id`/`ingredient_id` are set programmatically by
  `Tabletap.Inventory`, never cast from user attrs (code-standards.md).
  No archive/soft-delete — unlike a menu item or ingredient, a recipe
  line carries no independent history of its own (`Inventory.deduct_for_
  order/2` reads recipe lines live at serve time, never snapshots them),
  so removing one from a recipe is a plain delete.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "recipe_lines" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :menu_item, Tabletap.Catalog.MenuItem
    belongs_to :ingredient, Tabletap.Inventory.Ingredient

    field :qty_per_serving, :decimal

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def creation_changeset(recipe_line, attrs) do
    recipe_line
    |> cast(attrs, [:org_id, :menu_item_id, :ingredient_id, :qty_per_serving])
    |> validate_required([:org_id, :menu_item_id, :ingredient_id, :qty_per_serving])
    |> validate_number(:qty_per_serving, greater_than: 0)
    |> unique_constraint([:menu_item_id, :ingredient_id])
  end

  def qty_changeset(recipe_line, qty_per_serving) do
    recipe_line
    |> change(qty_per_serving: qty_per_serving)
    |> validate_number(:qty_per_serving, greater_than: 0)
  end
end

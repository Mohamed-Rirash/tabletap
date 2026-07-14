defmodule Tabletap.Inventory.RecipeLine do
  @moduledoc """
  One ingredient's quantity-per-serving on a menu item's bill of
  materials (architecture.md Data Model). Schema-only until Feature 12
  builds the recipe editor — `Inventory.deduct_for_order/2` (Feature 11)
  is the only reader so far.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "recipe_lines" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :menu_item, Tabletap.Catalog.MenuItem
    belongs_to :ingredient, Tabletap.Inventory.Ingredient

    field :qty_per_serving, :decimal

    timestamps(type: :utc_datetime, updated_at: false)
  end
end

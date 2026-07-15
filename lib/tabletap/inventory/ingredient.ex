defmodule Tabletap.Inventory.Ingredient do
  @moduledoc """
  A stocked ingredient (architecture.md Data Model; build-plan.md Feature
  12). Stock is kept in base units only (`g`/`ml`/`piece`) —
  `Inventory.UnitInput` converts a manager's free-typed quantity ("1.5
  kg") to the base unit at the input boundary; nothing downstream ever
  converts again.

  `stock_qty` is a cached sum — `stock_movements` is the append-only
  source of truth (architecture.md "stock_qty is derived and
  re-derivable"). It's deliberately **not** castable from
  `creation_changeset`/`update_changeset` — a brand-new ingredient always
  starts at zero and the manager restocks it from there
  (`Inventory.restock/5`), so every unit of stock that ever existed has a
  ledger row explaining it; there is no "opening balance" exception to
  that rule.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @units [:g, :ml, :piece]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "ingredients" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue

    field :name, :string
    field :unit, Ecto.Enum, values: @units
    field :stock_qty, :decimal, default: Decimal.new(0)
    field :min_threshold, :decimal
    field :cost_per_unit, Money.Ecto.Composite.Type
    field :active, :boolean, default: true
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def units, do: @units

  def creation_changeset(ingredient, attrs), do: validate(ingredient, attrs)
  def update_changeset(ingredient, attrs), do: validate(ingredient, attrs)

  defp validate(ingredient, attrs) do
    ingredient
    |> cast(attrs, [:name, :unit, :min_threshold, :cost_per_unit, :active])
    |> validate_required([:name, :unit])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_number(:min_threshold, greater_than_or_equal_to: 0)
  end

  @doc "Hides the ingredient from pickers (recipe editor, restock forms); every recipe_line/stock_movement FK and report stays intact (design-qa.md Q41)."
  def archive_changeset(ingredient),
    do: change(ingredient, archived_at: DateTime.utc_now(:second))
end

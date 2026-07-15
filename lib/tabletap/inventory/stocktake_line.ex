defmodule Tabletap.Inventory.StocktakeLine do
  @moduledoc """
  One ingredient's row within a `Tabletap.Inventory.StocktakeSession`
  (design-qa.md Q43) — `theoretical_qty_snapshot`/`unit_cost_snapshot`
  are frozen at session-start, `counted_qty` is filled in as the manager
  physically counts, `nil` until then.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "stocktake_lines" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :session, Tabletap.Inventory.StocktakeSession
    belongs_to :ingredient, Tabletap.Inventory.Ingredient

    field :theoretical_qty_snapshot, :decimal
    field :unit_cost_snapshot, Money.Ecto.Composite.Type
    field :counted_qty, :decimal

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def snapshot_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :org_id,
      :session_id,
      :ingredient_id,
      :theoretical_qty_snapshot,
      :unit_cost_snapshot
    ])
    |> validate_required([:org_id, :session_id, :ingredient_id, :theoretical_qty_snapshot])
  end

  def count_changeset(line, counted_qty) do
    line
    |> change(counted_qty: counted_qty)
    |> validate_number(:counted_qty, greater_than_or_equal_to: 0)
  end
end

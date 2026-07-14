defmodule Tabletap.Inventory.Ingredient do
  @moduledoc """
  A stocked ingredient (architecture.md Data Model; build-plan.md Feature
  12 owns the CRUD/UI — this schema lands early, in Feature 11, only
  because `Inventory.deduct_for_order/2` needs something to reference).
  Stock is kept in base units only (`g`/`ml`/`piece`); unit-conversion
  input helpers are Feature 12's job.

  `stock_qty` is a cached sum — `stock_movements` is the append-only
  source of truth (architecture.md "stock_qty is derived and
  re-derivable"). No archive changeset exists yet (no caller until
  Feature 12), but `archived_at` lands with the table per Q41's blanket
  archive-not-delete rule, so that feature isn't also a schema migration.
  """
  use Ecto.Schema

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
end

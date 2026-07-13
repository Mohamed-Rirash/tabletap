defmodule Tabletap.Ordering.OrderItemModifier do
  @moduledoc """
  One snapshotted chosen customization on an `OrderItem` (architecture.md
  Data Model) — "Extra cheese +$1.00" frozen exactly as it was at
  checkout, immune to the option's price or name changing later.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "order_item_modifiers" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :order_item, Tabletap.Ordering.OrderItem
    belongs_to :option, Tabletap.Catalog.ModifierOption

    field :name_snapshot, :string
    field :price_delta_snapshot, Money.Ecto.Composite.Type

    timestamps(type: :utc_datetime)
  end
end

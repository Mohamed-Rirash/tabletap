defmodule Tabletap.Ordering.OrderItem do
  @moduledoc """
  One snapshotted line on an `Order` (architecture.md Data Model). Unlike
  `Tabletap.Ordering.CartItem`, this never recomputes its price live —
  `name_snapshot`/`unit_price_snapshot`/`line_total` are frozen at
  checkout and survive any later menu edit.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "order_items" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :order, Tabletap.Ordering.Order
    belongs_to :menu_item, Tabletap.Catalog.MenuItem

    field :name_snapshot, :string
    field :unit_price_snapshot, Money.Ecto.Composite.Type
    field :qty, :integer
    field :line_total, Money.Ecto.Composite.Type
    field :notes, :string

    has_many :modifiers, Tabletap.Ordering.OrderItemModifier, foreign_key: :order_item_id

    timestamps(type: :utc_datetime)
  end
end

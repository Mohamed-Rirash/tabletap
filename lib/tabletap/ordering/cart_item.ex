defmodule Tabletap.Ordering.CartItem do
  @moduledoc """
  One line in a `Tabletap.Ordering.Cart` — a menu item, quantity, notes,
  and its selected modifier options (architecture.md Data Model). Holds
  no price of its own; `Tabletap.Ordering` computes line/cart totals live
  from the referenced `MenuItem.price` and each selected
  `ModifierOption.price_delta` every time (see `Cart`'s moduledoc).

  Each "add to cart" creates a new line rather than merging into an
  existing identical one — notes and quantity are edited per line
  afterward via the cart view, so there's no ambiguous "is this the same
  configuration" comparison to get right (Feature 07 build decision, not
  specified in the docs).

  `org_id`/`cart_id`/`menu_item_id` are set programmatically by
  `Tabletap.Ordering`, never cast from user attrs.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_qty 20

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "cart_items" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :cart, Tabletap.Ordering.Cart
    belongs_to :menu_item, Tabletap.Catalog.MenuItem

    field :qty, :integer, default: 1
    field :notes, :string

    has_many :cart_item_options, Tabletap.Ordering.CartItemOption, foreign_key: :cart_item_id
    has_many :options, through: [:cart_item_options, :option]

    timestamps(type: :utc_datetime)
  end

  def max_qty, do: @max_qty

  def creation_changeset(item, attrs), do: validate(item, attrs)
  def update_changeset(item, attrs), do: validate(item, attrs)

  defp validate(item, attrs) do
    item
    |> cast(attrs, [:qty, :notes])
    |> validate_required([:qty])
    |> validate_number(:qty, greater_than_or_equal_to: 1, less_than_or_equal_to: @max_qty)
    |> validate_length(:notes, max: 300)
  end
end

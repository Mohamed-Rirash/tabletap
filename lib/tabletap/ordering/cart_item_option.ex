defmodule Tabletap.Ordering.CartItemOption do
  @moduledoc """
  One selected `ModifierOption` on a `Tabletap.Ordering.CartItem` line —
  a pure join, same shape as `Tabletap.Catalog.ItemModifierGroup`. No
  price of its own (the option's live `price_delta` is looked up at
  total-computation time); revalidated against current modifier rules on
  every cart-view mount, never trusted as still-structurally-valid
  (design-qa.md Q42).

  All fields set programmatically by `Tabletap.Ordering`, never cast
  from user attrs.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "cart_item_options" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :cart_item, Tabletap.Ordering.CartItem
    belongs_to :option, Tabletap.Catalog.ModifierOption

    timestamps(type: :utc_datetime)
  end

  @doc """
  `Ordering.add_item/5` already checks the option belongs to a group
  attached to the item being added — the unique constraint turns a
  double-select of the same option into a changeset error instead of a
  raised `Ecto.ConstraintError`.
  """
  def creation_changeset(selection) do
    selection
    |> change()
    |> unique_constraint([:cart_item_id, :option_id],
      name: :cart_item_options_cart_item_id_option_id_index,
      message: "is already selected"
    )
  end
end

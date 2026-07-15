defmodule Tabletap.Catalog.ModifierOption do
  @moduledoc """
  One choice inside a `Tabletap.Catalog.ModifierGroup` — "Extra cheese
  +$1.00", "No onions $0" (architecture.md Data Model). `price_delta` is
  added to the item's base price when chosen; zero and negative deltas
  are both legal (removals cost nothing, downgrades can discount).
  `default` pre-selects the option in the customer's modifier sheet
  (Feature 07); `active` is the manager's temporary hide toggle,
  independent of archiving.

  `ingredient_id`/`ingredient_qty_delta` (build-plan.md Feature 12,
  architecture.md's data model) are the option's own stock effect on top
  of the item's base recipe — "Extra cheese" might carry `+20` (grams)
  against the cheese ingredient, "No onions" a `-15` against onions.
  Both nullable together: most options have no stock effect at all (a
  size/color choice, a free customization). `Inventory.deduct_for_order/2`
  is the only reader.

  `org_id`/`group_id` are set programmatically by `Tabletap.Catalog`,
  never cast from user attrs (code-standards.md); archived, never
  deleted (design-qa.md Q41 — Feature 08's `order_item_modifiers` rows
  will reference the option they were chosen from).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "modifier_options" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :group, Tabletap.Catalog.ModifierGroup
    belongs_to :ingredient, Tabletap.Inventory.Ingredient

    field :name, :string
    field :price_delta, Money.Ecto.Composite.Type
    field :default, :boolean, default: false
    field :active, :boolean, default: true
    field :position, :integer, default: 0
    field :ingredient_qty_delta, :decimal
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def creation_changeset(option, attrs), do: validate(option, attrs)
  def update_changeset(option, attrs), do: validate(option, attrs)

  defp validate(option, attrs) do
    option
    |> cast(attrs, [:name, :price_delta, :default, :active, :ingredient_id, :ingredient_qty_delta])
    |> validate_required([:name, :price_delta])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_ingredient_delta()
  end

  # Both-or-neither: a delta with no ingredient chosen (or vice versa) is
  # a half-filled form, not a valid "no stock effect" state (that's
  # simply leaving both blank).
  defp validate_ingredient_delta(changeset) do
    ingredient_id = get_field(changeset, :ingredient_id)
    delta = get_field(changeset, :ingredient_qty_delta)

    case {ingredient_id, delta} do
      {nil, nil} -> changeset
      {id, d} when not is_nil(id) and not is_nil(d) -> changeset
      {nil, _} -> add_error(changeset, :ingredient_id, "must choose an ingredient for this delta")
      {_, nil} -> add_error(changeset, :ingredient_qty_delta, "can't be blank")
    end
  end

  @doc "Hides the option from menus/pickers; every report, snapshot, and FK stays intact."
  def archive_changeset(option), do: change(option, archived_at: DateTime.utc_now(:second))
end

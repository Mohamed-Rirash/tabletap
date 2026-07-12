defmodule Tabletap.Catalog.ModifierOption do
  @moduledoc """
  One choice inside a `Tabletap.Catalog.ModifierGroup` — "Extra cheese
  +$1.00", "No onions $0" (architecture.md Data Model). `price_delta` is
  added to the item's base price when chosen; zero and negative deltas
  are both legal (removals cost nothing, downgrades can discount).
  `default` pre-selects the option in the customer's modifier sheet
  (Feature 07); `active` is the manager's temporary hide toggle,
  independent of archiving.

  The architecture data model also lists `ingredient_id` /
  `ingredient_qty_delta` (an option's stock effect) — those columns land
  with the `ingredients` table in Feature 12; there is nothing for them
  to reference yet.

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

    field :name, :string
    field :price_delta, Money.Ecto.Composite.Type
    field :default, :boolean, default: false
    field :active, :boolean, default: true
    field :position, :integer, default: 0
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def creation_changeset(option, attrs), do: validate(option, attrs)
  def update_changeset(option, attrs), do: validate(option, attrs)

  defp validate(option, attrs) do
    option
    |> cast(attrs, [:name, :price_delta, :default, :active])
    |> validate_required([:name, :price_delta])
    |> validate_length(:name, min: 1, max: 120)
  end

  @doc "Hides the option from menus/pickers; every report, snapshot, and FK stays intact."
  def archive_changeset(option), do: change(option, archived_at: DateTime.utc_now(:second))
end

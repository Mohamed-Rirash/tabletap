defmodule Tabletap.Catalog.ItemModifierGroup do
  @moduledoc """
  Attaches a reusable `ModifierGroup` to a `MenuItem` (architecture.md
  Data Model) — many-to-many, ordered per item by `position` (the order
  the customer's modifier sheet presents the groups in, Feature 07). A
  pure join row with no history value of its own: order snapshots
  (Feature 08) copy option names/deltas, so attach/detach rows are
  hard-deleted freely.

  All fields are set programmatically by `Tabletap.Catalog`, never cast
  from user attrs (code-standards.md).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "item_modifier_groups" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :item, Tabletap.Catalog.MenuItem
    belongs_to :group, Tabletap.Catalog.ModifierGroup

    field :position, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc """
  `Catalog.attach_group_to_item/3` already checks both sides share the
  scope's venue — the unique constraint turns a double-attach into a
  changeset error instead of a raised `Ecto.ConstraintError`.
  """
  def creation_changeset(attachment) do
    attachment
    |> change()
    |> unique_constraint([:item_id, :group_id],
      name: :item_modifier_groups_item_id_group_id_index,
      message: "is already attached to this item"
    )
  end
end

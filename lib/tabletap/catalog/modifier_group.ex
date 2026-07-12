defmodule Tabletap.Catalog.ModifierGroup do
  @moduledoc """
  A reusable set of customization choices for menu items — "Size",
  "Extras", "Remove" (architecture.md Data Model). Groups belong to a
  venue and attach to any number of its items through
  `Tabletap.Catalog.ItemModifierGroup`, so "Extras" is configured once
  and shared by every burger.

  Selection rules: a customer must pick at least `min_selections` and at
  most `max_selections` options. `required` marks the group as one the
  customer can't skip — a required group with `min_selections: 0` is
  contradictory, so the changeset rejects it (build-plan.md Feature 05
  verify step), as it rejects `max < min`.

  Archived, never deleted, once created (design-qa.md Q41 — order
  snapshots from Feature 08 will reference these groups' options);
  `org_id`/`venue_id` are set programmatically by `Tabletap.Catalog`,
  never cast from user attrs (code-standards.md).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "modifier_groups" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue

    field :name, :string
    field :min_selections, :integer, default: 0
    field :max_selections, :integer, default: 1
    field :required, :boolean, default: false
    field :archived_at, :utc_datetime

    has_many :options, Tabletap.Catalog.ModifierOption, foreign_key: :group_id

    timestamps(type: :utc_datetime)
  end

  def creation_changeset(group, attrs), do: validate(group, attrs)
  def update_changeset(group, attrs), do: validate(group, attrs)

  defp validate(group, attrs) do
    group
    |> cast(attrs, [:name, :min_selections, :max_selections, :required])
    |> validate_required([:name, :min_selections, :max_selections])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_number(:min_selections, greater_than_or_equal_to: 0)
    |> validate_number(:max_selections, greater_than_or_equal_to: 1)
    |> validate_max_not_below_min()
    |> validate_required_implies_min()
  end

  defp validate_max_not_below_min(changeset) do
    min = get_field(changeset, :min_selections)
    max = get_field(changeset, :max_selections)

    if is_integer(min) and is_integer(max) and max < min do
      add_error(changeset, :max_selections, "must be greater than or equal to min selections")
    else
      changeset
    end
  end

  defp validate_required_implies_min(changeset) do
    if get_field(changeset, :required) && get_field(changeset, :min_selections) == 0 do
      add_error(changeset, :min_selections, "must be at least 1 when the group is required")
    else
      changeset
    end
  end

  @doc "Hides the group from menus/pickers; every report, snapshot, and FK stays intact."
  def archive_changeset(group), do: change(group, archived_at: DateTime.utc_now(:second))
end

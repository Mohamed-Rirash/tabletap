defmodule Tabletap.Catalog.Category do
  @moduledoc """
  A flat (single-level — no nesting), reorderable grouping of a venue's
  menu items (architecture.md Data Model). Archived, never deleted, once
  it's ever had an item — design-qa.md Q41; `org_id`/`venue_id` are set
  programmatically by `Tabletap.Catalog`, never cast from user attrs
  (code-standards.md).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "menu_categories" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue

    field :name, :string
    field :position, :integer, default: 0
    field :active, :boolean, default: true
    field :archived_at, :utc_datetime

    has_many :items, Tabletap.Catalog.MenuItem, foreign_key: :category_id

    timestamps(type: :utc_datetime)
  end

  def creation_changeset(category, attrs), do: validate(category, attrs)
  def update_changeset(category, attrs), do: validate(category, attrs)

  defp validate(category, attrs) do
    category
    |> cast(attrs, [:name, :active])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
  end

  @doc "Hides the category from menus/pickers; every report, snapshot, and FK stays intact."
  def archive_changeset(category), do: change(category, archived_at: DateTime.utc_now(:second))

  def position_changeset(category, position), do: change(category, position: position)
end

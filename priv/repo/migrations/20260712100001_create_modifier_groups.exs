defmodule Tabletap.Repo.Migrations.CreateModifierGroups do
  use Ecto.Migration

  def change do
    create table(:modifier_groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :min_selections, :integer, null: false, default: 0
      add :max_selections, :integer, null: false, default: 1
      add :required, :boolean, null: false, default: false
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:modifier_groups, [:org_id])
    create index(:modifier_groups, [:venue_id])

    # Composite-FK target for modifier_options and item_modifier_groups —
    # same (id, org_id) pattern as venues/menu_categories/menu_items.
    create unique_index(:modifier_groups, [:id, :org_id])
  end
end

defmodule Tabletap.Repo.Migrations.CreateMenuCategories do
  use Ecto.Migration

  def change do
    create table(:menu_categories, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :position, :integer, null: false, default: 0
      add :active, :boolean, null: false, default: true
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:menu_categories, [:org_id])
    create index(:menu_categories, [:venue_id, :position])

    # Composite-FK target for menu_items — same pattern as venues'
    # (id, org_id) index (code-standards.md "Composite FKs").
    create unique_index(:menu_categories, [:id, :org_id])
  end
end

defmodule Tabletap.Repo.Migrations.CreateMenuItems do
  use Ecto.Migration

  def change do
    create table(:menu_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      # :restrict, not :delete_all — a category with items follows
      # archive-not-delete (design-qa.md Q41); it can't be hard-deleted
      # out from under its items.
      add :category_id,
          references(:menu_categories,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :restrict
          ),
          null: false

      add :name, :string, null: false
      add :description, :text
      add :photo_url, :string
      add :price, :money_with_currency, null: false
      add :prep_minutes, :integer
      add :active, :boolean, null: false, default: true
      add :available_today, :boolean, null: false, default: true
      add :dietary_tags, {:array, :string}, null: false, default: []
      add :allergen_tags, {:array, :string}, null: false, default: []
      add :position, :integer, null: false, default: 0
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:menu_items, [:org_id])
    create index(:menu_items, [:category_id, :position])

    # Composite-FK target for daily_item_limits (and Feature 05's
    # item_modifier_groups).
    create unique_index(:menu_items, [:id, :org_id])
  end
end

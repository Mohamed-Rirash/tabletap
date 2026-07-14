defmodule Tabletap.Repo.Migrations.CreateIngredients do
  use Ecto.Migration

  def change do
    create table(:ingredients, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      # Base units only (architecture.md "Data Model") — conversions
      # happen at input time, once Feature 12 builds the entry UI.
      add :unit, :string, null: false
      add :stock_qty, :decimal, null: false, default: 0
      add :min_threshold, :decimal
      add :cost_per_unit, :money_with_currency
      add :active, :boolean, null: false, default: true
      # Archive-not-delete (design-qa.md Q41) — no archive changeset/UI
      # exists yet (Feature 12's job), but the column lands with the
      # table so that feature isn't a schema migration too.
      add :archived_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:ingredients, [:org_id])
    create index(:ingredients, [:venue_id])
    # Composite-FK target for recipe_lines/stock_movements.
    create unique_index(:ingredients, [:id, :org_id])
  end
end

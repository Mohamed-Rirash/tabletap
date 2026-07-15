defmodule Tabletap.Repo.Migrations.CreateStocktakeLines do
  use Ecto.Migration

  def change do
    create table(:stocktake_lines, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :session_id,
          references(:stocktake_sessions,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      add :ingredient_id,
          references(:ingredients,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      # design-qa.md Q43 — snapshotted the moment the session starts, so
      # sales during the count can't move the number the count is
      # compared against. `unit_cost_snapshot` values the variance report
      # at what stock was worth *then*, not whatever it costs by the time
      # someone reads the report.
      add :theoretical_qty_snapshot, :decimal, null: false
      add :unit_cost_snapshot, :money_with_currency
      # Null until the manager actually counts this ingredient.
      add :counted_qty, :decimal

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:stocktake_lines, [:org_id])
    create unique_index(:stocktake_lines, [:session_id, :ingredient_id])
  end
end

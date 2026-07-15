defmodule Tabletap.Repo.Migrations.CreateStocktakeSessions do
  use Ecto.Migration

  def change do
    create table(:stocktake_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :started_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :closed_at, :utc_datetime
      add :status, :string, null: false, default: "open"

      timestamps(type: :utc_datetime)
    end

    create index(:stocktake_sessions, [:org_id])
    create index(:stocktake_sessions, [:venue_id, :status])
    create unique_index(:stocktake_sessions, [:id, :org_id])
  end
end

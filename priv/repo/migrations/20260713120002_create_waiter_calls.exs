defmodule Tabletap.Repo.Migrations.CreateWaiterCalls do
  use Ecto.Migration

  def change do
    create table(:waiter_calls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :table_id,
          references(:tables, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :order_id,
          references(:orders, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :status, :string, null: false, default: "open"

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:waiter_calls, [:org_id])
    create index(:waiter_calls, [:order_id])
    create index(:waiter_calls, [:venue_id, :status])
  end
end

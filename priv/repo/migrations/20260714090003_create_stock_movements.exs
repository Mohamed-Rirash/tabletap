defmodule Tabletap.Repo.Migrations.CreateStockMovements do
  use Ecto.Migration

  def change do
    create table(:stock_movements, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :ingredient_id,
          references(:ingredients,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      # Negative on deduction/wastage, positive on restock/adjustment —
      # append-only ledger (architecture.md); ingredients.stock_qty is a
      # derived cache, this table is the truth.
      add :qty_delta, :decimal, null: false
      add :reason, :string, null: false
      # Set on restocks only (Feature 13) — what was actually paid,
      # powering purchase-expense/profit reports later.
      add :unit_cost, :money_with_currency

      add :order_id,
          references(:orders, type: :binary_id, with: [org_id: :org_id], on_delete: :nilify_all)

      add :staff_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :note, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:stock_movements, [:org_id])
    create index(:stock_movements, [:ingredient_id])
    create index(:stock_movements, [:order_id])
    create index(:stock_movements, [:venue_id, :inserted_at])
  end
end

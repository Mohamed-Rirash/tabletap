defmodule Tabletap.Repo.Migrations.CreatePlatformFeeLedger do
  use Ecto.Migration

  def change do
    create table(:platform_fee_ledger, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :order_id,
          references(:orders, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :amount, :money_with_currency, null: false
      add :accrued_at, :utc_datetime, null: false
      add :settled_at, :utc_datetime
      # Feature 19's monthly invoice job stamps this once it collects the
      # accrual — no `invoices` table exists yet to FK against, so this
      # stays a bare uuid, same deferral pattern as elsewhere in this
      # codebase (e.g. Order.waiter_membership_id).
      add :invoice_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    create index(:platform_fee_ledger, [:org_id])
    create index(:platform_fee_ledger, [:venue_id])
    create index(:platform_fee_ledger, [:order_id])
    # Feature 19's monthly collection query shape: every unsettled accrual.
    create index(:platform_fee_ledger, [:org_id, :settled_at])
  end
end

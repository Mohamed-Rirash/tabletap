defmodule Tabletap.Repo.Migrations.CreatePayments do
  use Ecto.Migration

  def change do
    create table(:payments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :order_id,
          references(:orders, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :provider, :string, null: false
      add :provider_txn_id, :string
      add :wallet_msisdn_masked, :string
      add :amount, :money_with_currency, null: false
      add :status, :string, null: false, default: "pending"

      # Feature 15 (Cashier POS) territory, not populated by this feature —
      # architecture.md documents it, but no caller exists yet
      # (Order.waiter_membership_id's identical deferral pattern).

      timestamps(type: :utc_datetime)
    end

    create index(:payments, [:org_id])
    create index(:payments, [:venue_id])
    create index(:payments, [:order_id])

    # `requestId` = this row's id makes charge retries idempotent on the
    # WaafiPay side (library-docs.md); this index makes a duplicated or
    # replayed callback for the same transaction idempotent on ours.
    create unique_index(:payments, [:provider_txn_id])

    # The 30s reconciliation poller's query shape (build-plan.md Feature 09).
    create index(:payments, [:status])

    # Composite-FK target for refunds.
    create unique_index(:payments, [:id, :org_id])
  end
end

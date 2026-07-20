defmodule Tabletap.Repo.Migrations.CreateOffboardingTables do
  use Ecto.Migration

  def change do
    # build-plan.md Feature 19; design-qa.md Q15 — the owner-initiated
    # start of a tenant offboarding. Nullable: unset for every org that
    # hasn't asked to leave.
    alter table(:orgs) do
      add :offboarding_requested_at, :utc_datetime
    end

    # design-qa.md Q31 — "before tenant hard-delete, orders belonging to
    # account-holding customers are copied to a platform-level archive
    # (date, item name snapshots, quantities, totals, 'a closed venue')."
    # Deliberately flat/denormalized: no FK to the org or venue being
    # deleted (both die at the same 90-day mark this row is created),
    # only to the customer whose history this preserves — nilify_all so
    # the archive itself survives if that customer later deletes their
    # own account too (Accounts.delete_account/1), same anonymize-not-
    # delete discipline as orders.customer_user_id already established.
    create table(:platform_order_archives, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :customer_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :venue_name_snapshot, :string, null: false
      add :order_date, :date, null: false
      add :items, :map, null: false
      add :total, :money_with_currency, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:platform_order_archives, [:customer_user_id])

    # design-qa.md Q54 — "the payment + dispute-evidence subset (payment
    # rows, order snapshots, serve-scan timestamps) is retained 180 days
    # post-offboarding, then purged. Everything else still dies at 90
    # days." Same flat/denormalized shape as the archive above and for
    # the same reason: this row has to outlive the org/venue/payment
    # rows it summarizes, which are hard-deleted the same day this is
    # written (see Tabletap.Offboarding's own moduledoc for the full
    # two-stage design).
    create table(:payment_dispute_records, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_name_snapshot, :string, null: false
      add :order_number, :integer, null: false
      add :order_placed_at, :utc_datetime, null: false
      add :served_at, :utc_datetime
      add :provider, :string, null: false
      add :provider_txn_id, :string
      add :amount, :money_with_currency, null: false
      add :retain_until, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:payment_dispute_records, [:retain_until])
  end
end

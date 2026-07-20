defmodule Tabletap.Repo.Migrations.CreateInvoicesAndBillingWallet do
  use Ecto.Migration

  def change do
    # build-plan.md Feature 19 / design-qa.md Q59 — the row
    # `platform_fee_ledger.invoice_id` was already anticipating
    # ("no `invoices` table exists yet to FK against" — that migration's
    # own comment). One row per org per billing period: inserted
    # `pending` *before* the wallet push-prompt charge is attempted
    # (same idempotency shape `payments` uses for a venue's own
    # charges — the unique index below is what actually stops a
    # double-collect of one period, not just application-level care).
    create table(:invoices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :plan, :string, null: false
      add :plan_amount, :money_with_currency, null: false
      add :period_start, :date, null: false
      add :period_end, :date, null: false

      add :status, :string, null: false, default: "pending"
      add :provider_txn_id, :string
      add :failure_reason, :string
      add :attempted_at, :utc_datetime
      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:invoices, [:org_id])
    create unique_index(:invoices, [:org_id, :period_start])
    create unique_index(:invoices, [:id, :org_id])

    # The owner's own wallet number, collected on the billing screen —
    # separate from any venue's WaafiPay merchant credentials (those
    # receive customer payments; this is who Tabletap's platform
    # merchant account pushes a PIN prompt *to* for the subscription
    # itself, design-qa.md Q59). Nullable: unset until the owner visits
    # /settings/billing at least once.
    alter table(:orgs) do
      add :billing_wallet_msisdn, :string
    end

    # Upgrades platform_fee_ledger.invoice_id from a bare uuid (its own
    # migration's deferred placeholder) to a real composite FK now that
    # `invoices` exists — a ledger row can never end up pointing at
    # another org's invoice (code-standards.md "Tenancy Rules").
    # nilify_all, not cascade: deleting an invoice (shouldn't normally
    # happen) must never take a venue's real accrued-fee history with it.
    alter table(:platform_fee_ledger) do
      modify :invoice_id,
             references(:invoices,
               type: :binary_id,
               with: [org_id: :org_id],
               on_delete: :nilify_all
             ),
             from: :binary_id
    end
  end
end

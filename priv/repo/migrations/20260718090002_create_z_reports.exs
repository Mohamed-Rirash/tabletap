defmodule Tabletap.Repo.Migrations.CreateZReports do
  use Ecto.Migration

  def change do
    # design-qa.md Q20/"Gap Analysis" End-of-day close: one closed report
    # per venue per business day. `totals` is a jsonb snapshot (order
    # count, revenue/discount/refund totals, a per-payment-provider
    # breakdown) — a closed day's numbers are a point-in-time record, not
    # a live view, so they're captured rather than recomputed on read
    # (Q38's "the original close stays visible as closed" needs somewhere
    # to stay).
    create table(:z_reports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :business_date, :date, null: false

      add :closed_by_membership_id,
          references(:memberships,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :restrict
          ),
          null: false

      add :closed_at, :utc_datetime, null: false
      add :totals, :map, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:z_reports, [:org_id])
    create unique_index(:z_reports, [:venue_id, :business_date])
    create unique_index(:z_reports, [:id, :org_id])

    # design-qa.md Q22 "expected vs counted cash per cashier shift" — one
    # row per cashier (membership) that took cash within the closed
    # business day, so the drawer reconciliation is attributable per
    # person, not just a venue-wide total.
    create table(:z_report_cash_counts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :z_report_id,
          references(:z_reports,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :delete_all
          ),
          null: false

      add :membership_id,
          references(:memberships,
            type: :binary_id,
            with: [org_id: :org_id],
            on_delete: :restrict
          ),
          null: false

      add :expected_cash, :money_with_currency, null: false
      add :counted_cash, :money_with_currency, null: false
      add :variance, :money_with_currency, null: false
      add :notes, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:z_report_cash_counts, [:org_id])
    create unique_index(:z_report_cash_counts, [:z_report_id, :membership_id])
  end
end

defmodule Tabletap.Repo.Migrations.CreateDailyRollups do
  use Ecto.Migration

  def change do
    # build-plan.md Feature 18 / architecture.md's documented data-model
    # row: one nightly-computed row per venue per business day, feeding
    # owner-dashboard.md's Screens 2-7 + Report Center. Never a "closed"
    # document like `z_reports` — freely recomputed as new events land on
    # a past business day; `recompute_count` (0 on first insert) lets any
    # reader show a lightweight "adjusted" signal without a snapshot/diff
    # mechanism (design-qa.md Q37/Q38 — see `Tabletap.Analytics`'s own
    # moduledoc for the full reasoning).
    create table(:daily_rollups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:orgs, type: :binary_id, on_delete: :delete_all), null: false

      add :venue_id,
          references(:venues, type: :binary_id, with: [org_id: :org_id], on_delete: :delete_all),
          null: false

      add :date, :date, null: false

      add :gross_sales, :money_with_currency, null: false
      add :discounts, :money_with_currency, null: false
      add :refunds, :money_with_currency, null: false
      add :net_revenue, :money_with_currency, null: false
      add :order_count, :integer, null: false, default: 0
      # Nullable — there's no meaningful average of zero orders, and
      # `nil` here is more honest than a manufactured `$0.00`.
      add :avg_check, :money_with_currency
      add :food_cost, :money_with_currency, null: false

      # Per-dimension breakdowns — jsonb, same raw-decimal-string storage
      # discipline `Payments.money_for_storage/1` already established
      # (never `Money.to_string!/2` in storage: that needs a locale and
      # the "so" locale has no CLDR data — a known gap, display-time only).
      add :channel_mix, :map, null: false, default: %{}
      add :payment_mix, :map, null: false, default: %{}
      add :hourly_orders, :map, null: false, default: %{}
      add :items_sold, :map, null: false, default: %{}
      add :ingredient_usage, :map, null: false, default: %{}
      add :staff_metrics, :map, null: false, default: %{}

      add :recompute_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:daily_rollups, [:org_id])
    create unique_index(:daily_rollups, [:venue_id, :date])
    create unique_index(:daily_rollups, [:id, :org_id])
  end
end

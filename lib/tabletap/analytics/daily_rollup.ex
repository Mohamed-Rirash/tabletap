defmodule Tabletap.Analytics.DailyRollup do
  @moduledoc """
  One nightly-computed row per venue per business day (build-plan.md
  Feature 18; architecture.md's documented data-model row). Screens 2-7
  of owner-dashboard.md and every Report Center report read from these
  rows plus today's live delta — never a "closed" document the way
  `Payments.ZReport` is: `Tabletap.Analytics.Workers.DailyRollup`
  freely recomputes the last several business days every night, so a
  late-landing payment/refund/order self-heals within days rather than
  requiring an explicit per-event recompute trigger threaded through
  every write path in `Ordering`/`Payments`. `recompute_count` (0 on
  first insert, incremented on every subsequent upsert) is the only
  signal a reader needs to show "this day's numbers moved after it
  closed" — no snapshot/diff machinery required (design-qa.md Q37/Q38).

  jsonb breakdowns store raw decimal-string amounts, never
  `Money.to_string!/2` — same discipline `Payments.close_z_report/3`
  already established, since storage needs no locale and the "so"
  locale has no CLDR data to format with anyway.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "daily_rollups" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue

    field :date, :date

    field :gross_sales, Money.Ecto.Composite.Type
    field :discounts, Money.Ecto.Composite.Type
    field :refunds, Money.Ecto.Composite.Type
    field :net_revenue, Money.Ecto.Composite.Type
    field :order_count, :integer, default: 0
    field :avg_check, Money.Ecto.Composite.Type
    field :food_cost, Money.Ecto.Composite.Type

    field :channel_mix, :map, default: %{}
    field :payment_mix, :map, default: %{}
    field :hourly_orders, :map, default: %{}
    field :items_sold, :map, default: %{}
    field :ingredient_usage, :map, default: %{}
    field :staff_metrics, :map, default: %{}

    field :recompute_count, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end

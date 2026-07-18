defmodule Tabletap.Payments.ZReport do
  @moduledoc """
  A closed business-day close (design-qa.md's Gap Analysis "End-of-day
  close (Z-report)"; build-plan.md Feature 15). One row per venue per
  business date (`unique_index(:z_reports, [:venue_id, :business_date])`)
  — closing twice for the same day is a bug, not a re-close
  (`Payments.close_z_report/3` checks first).

  `totals` is a point-in-time jsonb snapshot (order count, revenue,
  discounts, refunds, a per-provider breakdown) rather than something
  recomputed live on every read — design-qa.md Q38's "the original close
  stays visible as closed" needs the closed number to stop moving the
  instant it's closed, even if a late-arriving order/refund lands on
  that business date afterward (a post-close adjustment, flagged
  separately — not built by this feature; the Z-report itself is the
  place a future feature would render that flag against).
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "z_reports" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue

    belongs_to :closed_by_membership, Tabletap.Tenants.Membership,
      foreign_key: :closed_by_membership_id

    field :business_date, :date
    field :closed_at, :utc_datetime
    field :totals, :map

    has_many :cash_counts, Tabletap.Payments.ZReportCashCount

    timestamps(type: :utc_datetime, updated_at: false)
  end
end

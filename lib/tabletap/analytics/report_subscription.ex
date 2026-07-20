defmodule Tabletap.Analytics.ReportSubscription do
  @moduledoc """
  A manager/owner's opt-in to receive one Report Center report
  (`Tabletap.Analytics.Reports`) by email on a recurring cadence
  (build-plan.md Feature 18). `Workers.SendScheduledReports` re-checks
  the owning membership's `active` flag and role fresh at send time
  rather than trusting anything cached here — design-qa.md Q52.
  """
  use Ecto.Schema
  import Ecto.Changeset

  # A plain literal list, not `Reports.report_types()` — `Reports`
  # pattern-matches `%ReportSubscription{}` at compile time (in
  # `subscribe/3`'s struct literal), so referencing `Reports` back from
  # here would deadlock the two files' compilation.
  @report_types [
    :revenue,
    :orders,
    :successful_orders,
    :payments,
    :cashier_daily_cash,
    :assisted_orders,
    :inventory,
    :menu_performance,
    :feedback,
    :employee_work,
    :customers,
    :day_close,
    :profit
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "report_subscriptions" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue
    belongs_to :membership, Tabletap.Tenants.Membership

    field :report_type, Ecto.Enum, values: @report_types
    field :frequency, Ecto.Enum, values: [:daily, :weekly, :monthly]
    field :last_sent_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:org_id, :venue_id, :membership_id, :report_type, :frequency])
    |> validate_required([:org_id, :venue_id, :membership_id, :report_type, :frequency])
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:venue_id)
    |> foreign_key_constraint(:membership_id)
    |> unique_constraint([:membership_id, :venue_id, :report_type, :frequency],
      name: :report_subscriptions_membership_venue_report_frequency_index,
      message: "already subscribed to this report at this frequency"
    )
  end
end

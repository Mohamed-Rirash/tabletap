defmodule Tabletap.Payments.ZReportCashCount do
  @moduledoc """
  One cashier's drawer reconciliation within a closed `ZReport`
  (design-qa.md Q22 "expected vs counted cash per cashier shift"; matches
  owner-dashboard.md's "Cashier daily cash report" grain of one row per
  cashier per business day, not one row per literal clock-in/out shift —
  a cashier who clocks in and out twice in one day reconciles once,
  against everything they took that whole business day).

  `variance = counted_cash - expected_cash`, always stored (not derived
  on read) so a closed report's numbers never shift under a later
  `Money` rounding-mode change.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "z_report_cash_counts" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :z_report, Tabletap.Payments.ZReport
    belongs_to :membership, Tabletap.Tenants.Membership

    field :expected_cash, Money.Ecto.Composite.Type
    field :counted_cash, Money.Ecto.Composite.Type
    field :variance, Money.Ecto.Composite.Type
    field :notes, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end
end

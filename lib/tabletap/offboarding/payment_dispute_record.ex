defmodule Tabletap.Offboarding.PaymentDisputeRecord do
  @moduledoc """
  A flat, denormalized snapshot of one payment, kept alive independent
  of the org/venue/payment row it summarizes (build-plan.md Feature
  19; design-qa.md Q54: "the payment + dispute-evidence subset (payment
  rows, order snapshots, serve-scan timestamps) is retained 180 days
  post-offboarding, then purged"). Written at the same moment the
  originating org is hard-deleted (90 days post-offboarding), so it
  has to carry everything a chargeback investigation might need
  without any live FK to lean on.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "payment_dispute_records" do
    field :org_name_snapshot, :string
    field :order_number, :integer
    field :order_placed_at, :utc_datetime
    field :served_at, :utc_datetime
    field :provider, :string
    field :provider_txn_id, :string
    field :amount, Money.Ecto.Composite.Type
    field :retain_until, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end
end

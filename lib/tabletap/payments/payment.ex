defmodule Tabletap.Payments.Payment do
  @moduledoc """
  One charge attempt against one order (architecture.md Data Model;
  build-plan.md Feature 09). `provider_txn_id` is the WaafiPay-side
  idempotency key — a callback or poll for the same transaction resolves
  through the same row, never a duplicate (unique index).

  A **new** row is created per charge attempt, not reused across retries
  — `requestId` sent to WaafiPay is this row's id (library-docs.md), so
  each attempt needs its own fresh id to stay idempotent on their side
  too.
  """
  use Ecto.Schema

  @statuses [:pending, :succeeded, :refunded, :failed, :expired]
  @providers [:waafipay, :edahab, :chapa, :stripe, :cash, :comp]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "payments" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue
    belongs_to :order, Tabletap.Ordering.Order

    field :provider, Ecto.Enum, values: @providers
    field :provider_txn_id, :string
    field :wallet_msisdn_masked, :string
    field :amount, Money.Ecto.Composite.Type
    field :status, Ecto.Enum, values: @statuses, default: :pending

    has_many :refunds, Tabletap.Payments.Refund

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def providers, do: @providers
end

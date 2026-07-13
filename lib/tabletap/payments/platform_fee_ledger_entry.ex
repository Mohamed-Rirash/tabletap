defmodule Tabletap.Payments.PlatformFeeLedgerEntry do
  @moduledoc """
  One order's accrued platform fee (architecture.md Data Model;
  design-qa.md Q59). No split-payment API exists on wallet rails, so
  this is a ledger entry, not a real-time deduction — Feature 19's
  monthly invoice job is the only future writer of `settled_at`/
  `invoice_id`, both nil until then.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "platform_fee_ledger" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue
    belongs_to :order, Tabletap.Ordering.Order

    field :amount, Money.Ecto.Composite.Type
    field :accrued_at, :utc_datetime
    field :settled_at, :utc_datetime
    field :invoice_id, Ecto.UUID

    timestamps(type: :utc_datetime)
  end
end

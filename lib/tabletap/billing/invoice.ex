defmodule Tabletap.Billing.Invoice do
  @moduledoc """
  One org's billing-period invoice (build-plan.md Feature 19;
  design-qa.md Q59 — "monthly, itemized: plan price + accrued fees, one
  invoice per org"). Inserted `pending` **before** the wallet
  push-prompt charge is attempted — the row itself is the idempotency
  guard (same shape `Payments.Payment`'s `pending` row plays for a
  venue's own charges), and the unique `(org_id, period_start)` index
  is what actually stops a period from ever being double-collected, not
  just application-level care.

  `plan_amount` is a snapshot of what the org's plan cost *at billing
  time* — never recomputed from `Tabletap.Plans` after the fact, so a
  mid-cycle plan change can't silently rewrite an already-sent invoice.
  The fee line items themselves aren't duplicated onto this row; they
  live as the `platform_fee_ledger` rows this invoice settles
  (`belongs_to :invoice` on that schema), summed at render time.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "invoices" do
    belongs_to :org, Tabletap.Tenants.Org

    field :plan, Ecto.Enum, values: [:essentials, :growth, :pro]
    field :plan_amount, Money.Ecto.Composite.Type
    field :period_start, :date
    field :period_end, :date

    field :status, Ecto.Enum, values: [:pending, :succeeded, :failed], default: :pending
    field :provider_txn_id, :string
    field :failure_reason, :string
    field :attempted_at, :utc_datetime
    field :resolved_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [:org_id, :plan, :plan_amount, :period_start, :period_end])
    |> validate_required([:org_id, :plan, :plan_amount, :period_start, :period_end])
    |> foreign_key_constraint(:org_id)
    |> unique_constraint([:org_id, :period_start],
      message: "already has an invoice for this period"
    )
  end

  @doc "Marks a pending invoice succeeded — `attempted_at` set by the caller before the provider call, this stamps the outcome."
  def succeed_changeset(invoice, provider_txn_id) do
    change(invoice,
      status: :succeeded,
      provider_txn_id: provider_txn_id,
      resolved_at: DateTime.utc_now(:second)
    )
  end

  def fail_changeset(invoice, reason) do
    change(invoice,
      status: :failed,
      failure_reason: inspect(reason),
      resolved_at: DateTime.utc_now(:second)
    )
  end

  def attempted_changeset(invoice) do
    change(invoice, attempted_at: DateTime.utc_now(:second))
  end
end

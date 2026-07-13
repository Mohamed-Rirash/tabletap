defmodule Tabletap.Payments.Refund do
  @moduledoc """
  One refund against a `Payment` (architecture.md Data Model). Full or
  line-item partial (design-qa.md Q4); `provider_refund_id: nil` means a
  cash refund (Q22), subtracted from expected cash in shift/Z-reports —
  not a missing value. Over-refund guard (Q35) lives in
  `Tabletap.Payments.refund/4`, not here — this changeset only shapes
  data, it doesn't lock or validate against the payment's paid total.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pending, :succeeded, :failed]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "refunds" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :payment, Tabletap.Payments.Payment
    belongs_to :staff_user, Tabletap.Accounts.User, foreign_key: :staff_user_id

    field :amount, Money.Ecto.Composite.Type
    field :reason, :string
    field :provider_refund_id, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def new_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :org_id,
      :payment_id,
      :staff_user_id,
      :amount,
      :reason,
      :provider_refund_id,
      :status
    ])
    |> validate_required([:org_id, :payment_id, :amount, :reason, :status])
    |> validate_length(:reason, min: 1)
  end

  def status_changeset(refund, status, provider_refund_id \\ nil) when status in @statuses do
    changes = %{status: status}

    changes =
      if provider_refund_id,
        do: Map.put(changes, :provider_refund_id, provider_refund_id),
        else: changes

    change(refund, changes)
  end
end

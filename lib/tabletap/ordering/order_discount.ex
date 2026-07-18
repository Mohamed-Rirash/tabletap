defmodule Tabletap.Ordering.OrderDiscount do
  @moduledoc """
  One attributed discount against an order (architecture.md Data Model;
  build-plan.md Feature 15; design-qa.md Q36). `order_item_id: nil` means
  a whole-order discount; set, a line-level one. Rows are immutable once
  the order leaves `pending_payment` (Q36 "after payment, every goodwill
  gesture is a refund") — enforced by `Ordering.apply_discount/4`'s own
  status guard, not by anything here.

  Never unattributed (code-standards.md) — `staff_membership_id` is
  required, always the staff member who applied it (a cashier for an
  ordinary discount; a manager/owner for the 100%-discount comp path,
  `Tabletap.Payments.charge_comp/4`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "order_discounts" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :order, Tabletap.Ordering.Order
    belongs_to :order_item, Tabletap.Ordering.OrderItem
    belongs_to :staff_membership, Tabletap.Tenants.Membership, foreign_key: :staff_membership_id

    field :amount, Money.Ecto.Composite.Type
    field :reason, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def new_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:org_id, :order_id, :order_item_id, :staff_membership_id, :amount, :reason])
    |> validate_required([:org_id, :order_id, :staff_membership_id, :amount, :reason])
    |> validate_length(:reason, min: 1)
  end
end

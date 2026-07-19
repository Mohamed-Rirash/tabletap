defmodule Tabletap.Ordering.Order do
  @moduledoc """
  A placed (or placing) order — the core aggregate (architecture.md Data
  Model; build-plan.md Feature 08). Snapshots its line items' names and
  prices (`Tabletap.Ordering.OrderItem`/`OrderItemModifier`) so later menu
  edits never change history (code-standards.md "Snapshots over joins").

  `waiter_membership_id` lands in Feature 10 (waiter assignment).
  `placed_by_membership_id` (architecture.md's data-model row) is `nil`
  for a customer's own QR order and set to the cashier's membership when
  a staff member places it on a customer's behalf (build-plan.md Feature
  15's "cashier as full customer proxy" — powers the Assisted Orders
  report, owner-dashboard.md).
  `customer_user_id` (build-plan.md Feature 16) is `nil` for a guest who
  never signed up; `Ordering.link_guest_orders_to_customer/2` stamps it
  across every org matching a `guest_token` at post-order magic-link
  signup — the mechanism behind design-qa.md's "cross-venue history":
  the same customer's orders at different venues (different orgs) share
  no other identity, only this column.

  `flag` (design-qa.md Q9 "Can't find customer" / Q32 pickup no-show /
  Q27 "contains an 86'd item") — one shared column rather than three
  near-identical booleans, since all three mean the same thing
  operationally: this order needs a human to resolve it. `nil` means
  nothing is wrong. The three never collide in practice — Q27 only ever
  flags orders still in the kitchen (`placed`/`accepted`/`preparing`),
  while Q9/Q32 only ever flag a `ready` order, so a single column has
  never needed to hold more than one flag at once.

  Status changes only through `Ordering.OrderStateMachine.transition/3` —
  never `update_changeset`/`Repo.update` directly on `:status`
  (code-standards.md "Ordering & Payments Rules").
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [
    :pending_payment,
    :placed,
    :accepted,
    :preparing,
    :ready,
    :served,
    :closed,
    :expired,
    :cancelled,
    :refunded
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @flags [:unserveable, :not_picked_up, :contains_86d_item]

  schema "orders" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue
    belongs_to :table, Tabletap.Tenants.Table
    belongs_to :waiter_membership, Tabletap.Tenants.Membership, foreign_key: :waiter_membership_id

    belongs_to :placed_by_membership, Tabletap.Tenants.Membership,
      foreign_key: :placed_by_membership_id

    belongs_to :customer_user, Tabletap.Accounts.User, foreign_key: :customer_user_id

    field :guest_token, :string
    field :number, :integer
    field :business_date, :date
    field :kind, Ecto.Enum, values: [:dine_in, :takeaway, :counter]
    field :status, Ecto.Enum, values: @statuses, default: :pending_payment

    field :placed_at, :utc_datetime
    field :accepted_at, :utc_datetime
    field :ready_at, :utc_datetime
    field :served_at, :utc_datetime
    field :closed_at, :utc_datetime

    field :subtotal, Money.Ecto.Composite.Type
    field :discount_total, Money.Ecto.Composite.Type
    field :total, Money.Ecto.Composite.Type
    field :notes, :string

    field :flag, Ecto.Enum, values: @flags
    field :flagged_at, :utc_datetime

    has_many :items, Tabletap.Ordering.OrderItem, foreign_key: :order_id

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def flags, do: @flags

  @doc "A brand-new pending_payment order — built entirely from programmatically-computed attrs, never cast from user input (Ordering.checkout/N)."
  def new_changeset(attrs) do
    %__MODULE__{}
    |> change(attrs)
    |> validate_required([
      :org_id,
      :venue_id,
      :guest_token,
      :number,
      :business_date,
      :kind,
      :subtotal,
      :discount_total,
      :total
    ])
  end

  @doc """
  `OrderStateMachine`'s own write — sets `status` and, when the
  transition has one, the matching `..._at` timestamp. The *validity* of
  the transition itself is `OrderStateMachine.transition/3`'s job, not
  this changeset's — by the time this is called the move is already
  known-legal.
  """
  def transition_changeset(order, status, timestamp_field \\ nil, timestamp \\ nil) do
    changes = %{status: status}
    changes = if timestamp_field, do: Map.put(changes, timestamp_field, timestamp), else: changes
    change(order, changes)
  end

  @doc "Assignment (build-plan.md Feature 10) — `nil` unassigns (escalation, off-shift handoff)."
  def assign_waiter_changeset(order, membership_id) do
    change(order, waiter_membership_id: membership_id)
  end

  @doc "Flags an order needing manager attention (design-qa.md Q9/Q32) — always timestamped."
  def flag_changeset(order, flag) when flag in @flags do
    change(order, flag: flag, flagged_at: DateTime.utc_now(:second))
  end

  def clear_flag_changeset(order), do: change(order, flag: nil, flagged_at: nil)

  @doc """
  Re-derives `discount_total`/`total` after an `order_discounts` row is
  added or removed (build-plan.md Feature 15; design-qa.md Q36 — legal
  only while the order is still `pending_payment`, enforced by the
  caller, `Ordering.apply_discount/4`/`remove_discount/2`, not here).
  `subtotal` never changes post-checkout — only what's deducted from it.
  """
  def recompute_totals_changeset(order, discount_total) do
    change(order,
      discount_total: discount_total,
      total: Money.sub!(order.subtotal, discount_total)
    )
  end

  @doc """
  Unserveable-order resolution (build-plan.md Feature 11, design-qa.md
  Q9/Q10): the customer couldn't be found, so they'll collect this
  themselves instead of waiting on a waiter delivery — clears the flag
  and drops the assignment in the same write.
  """
  def convert_to_takeaway_changeset(order) do
    change(order, kind: :takeaway, waiter_membership_id: nil, flag: nil, flagged_at: nil)
  end
end

defmodule Tabletap.Ordering.Order do
  @moduledoc """
  A placed (or placing) order — the core aggregate (architecture.md Data
  Model; build-plan.md Feature 08). Snapshots its line items' names and
  prices (`Tabletap.Ordering.OrderItem`/`OrderItemModifier`) so later menu
  edits never change history (code-standards.md "Snapshots over joins").

  `waiter_membership_id`/`placed_by_membership_id` (architecture.md's
  data-model row) are deliberately not columns yet — same deferral
  `Tenants.Venue` used for its own not-yet-needed fields: they belong to
  Feature 10 (waiter assignment) and Feature 15 (cashier POS)
  respectively, added in those features' own migrations when a real
  caller exists. `customer_user_id` is deferred to Feature 16, matching
  `Ordering.Cart`'s identical deferral.

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
  schema "orders" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue
    belongs_to :table, Tabletap.Tenants.Table

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

    has_many :items, Tabletap.Ordering.OrderItem, foreign_key: :order_id

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

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
end

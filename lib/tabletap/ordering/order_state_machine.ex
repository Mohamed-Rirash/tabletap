defmodule Tabletap.Ordering.OrderStateMachine do
  @moduledoc """
  The single authority for order status changes (code-standards.md
  "Status changes only via `Ordering.OrderStateMachine.transition/3` —
  direct `status` updates are forbidden, including in tests").

  Full transition table (CONTEXT.md; design-qa.md Q1/Q25):

  ```
  pending_payment ──► placed ──► accepted ──► preparing ──► ready ──► served ──► closed
        │                │            │       ▲    │        ▲
        │                │            │       └────┘        │
        ▼                ▼            ▼      (undo)         └──────(undo)
     expired         cancelled    refunded  refunded       refunded
     cancelled
        │
        └──► placed  (late-success resurrection, design-qa.md Q21 — a
                       WaafiPay charge confirms APPROVED after the
                       12-min sweep already expired the order; legal
                       only once `Ordering.reserve_holds_for_order/1`
                       has re-reserved the stock the sweep released)
  ```

  `served` is irreversible (Q25) — no transition leads back out of it
  except forward to `closed`, or to `refunded` (a post-serve goodwill
  refund, still legal). One-step-back undo exists for exactly two pairs:
  `ready → preparing` (clears `ready_at` — Q25 "retracts the waiter's
  pickup notification") and `preparing → accepted`. `cancelled` is only
  legal from pre-kitchen states (`pending_payment`/`placed`/`accepted`)
  — CONTEXT.md's void/comp distinction: cancelling is the "never made"
  path, not appropriate once the kitchen has committed to `preparing`.

  Illegal transitions **raise** — code-standards.md: "contexts don't
  raise for expected failures; they raise only for bugs (e.g., illegal
  state transitions)." A caller only ever attempts a transition a UI
  button already gated on `legal?/2`, so reaching an illegal one means
  something upstream is wrong, not a normal user error to hand back as
  `{:error, _}`.

  Only four transitions touch `daily_item_limits` (Q1's hold mechanics)
  — `pending_payment → placed` and `expired → placed` (resurrection)
  both convert a hold (`reserved_qty -= n, sold_qty += n`; resurrection's
  hold was put back by `Ordering.reserve_holds_for_order/1` just before
  this call, so the same conversion applies), `pending_payment →
  expired` and `pending_payment → cancelled` release one
  (`reserved_qty -= n`). Everything past `pending_payment`/`expired` has
  already resolved its stock question and never touches limits again.
  """

  import Ecto.Query, warn: false

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog.DailyItemLimit
  alias Tabletap.Ordering.Order
  alias Tabletap.Repo

  @transitions %{
    pending_payment: [:placed, :expired, :cancelled],
    placed: [:accepted, :cancelled, :refunded],
    accepted: [:preparing, :cancelled, :refunded],
    preparing: [:ready, :accepted, :refunded],
    ready: [:served, :preparing, :refunded],
    served: [:closed, :refunded],
    closed: [:refunded],
    expired: [:placed],
    cancelled: [],
    refunded: []
  }

  @doc "Every status an order can ever be in."
  def statuses, do: Order.statuses()

  @doc "Whether `from -> to` is a legal move."
  def legal?(from, to), do: to in Map.fetch!(@transitions, from)

  @doc "The set of statuses legally reachable from `from` — the UI's own guide for which action buttons to show."
  def legal_transitions(from), do: Map.fetch!(@transitions, from)

  @doc """
  Moves `order` from its current status to `to`. Settles any daily-limit
  hold the transition implies, writes the new status (+ the matching
  `..._at` timestamp, if that status has one), emits telemetry, and
  broadcasts on `"order:<id>"` — all after the same transaction commits,
  never before (a broadcast from inside the transaction could fire even
  if a later step then rolled everything back).

  Raises `ArgumentError` for an illegal transition (see moduledoc — a
  bug, not a user-facing error).
  """
  def transition(%Scope{} = scope, %Order{} = order, to) do
    from = order.status

    unless legal?(from, to) do
      raise ArgumentError, "illegal order transition: #{from} -> #{to}"
    end

    order = Repo.preload(order, :items)

    Ecto.Multi.new()
    |> Ecto.Multi.run(:holds, fn _repo, _changes -> settle_holds(order, from, to) end)
    |> Ecto.Multi.update(:order, fn _changes -> build_changeset(order, from, to) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{order: updated}} ->
        emit_telemetry(scope, updated, from, to)
        broadcast(updated)
        maybe_enqueue_assignment(updated, to)
        {:ok, updated}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Assignment is a side-effect Oban job, never inline here (architecture.md
  # "Reliability" — a crash mid-assignment survives as a retryable job,
  # and the state machine itself stays focused on the transition alone).
  # build-plan.md Feature 10.
  defp maybe_enqueue_assignment(order, :placed) do
    %{order_id: order.id, org_id: order.org_id}
    |> Tabletap.Ordering.Workers.AssignWaiter.new()
    |> Oban.insert()
  end

  defp maybe_enqueue_assignment(_order, _to), do: :ok

  defp build_changeset(order, :ready, :preparing) do
    # One-step-back undo (Q25) — the retracted state's timestamp goes
    # with it; the waiter/customer screens should no longer see a
    # ready_at that's no longer true.
    Order.transition_changeset(order, :preparing) |> Ecto.Changeset.put_change(:ready_at, nil)
  end

  defp build_changeset(order, _from, to) do
    Order.transition_changeset(order, to, timestamp_field(to), DateTime.utc_now(:second))
  end

  defp timestamp_field(:placed), do: :placed_at
  defp timestamp_field(:accepted), do: :accepted_at
  defp timestamp_field(:ready), do: :ready_at
  defp timestamp_field(:served), do: :served_at
  defp timestamp_field(:closed), do: :closed_at
  defp timestamp_field(_status), do: nil

  ## Daily-limit hold settlement (design-qa.md Q1) — only four
  ## transitions touch reserved_qty/sold_qty.

  # :expired here is the Q21 resurrection path — the caller has already
  # called Ordering.reserve_holds_for_order/1 to put the hold back, so
  # this is the exact same reserved->sold conversion as the normal
  # pending_payment case.
  defp settle_holds(order, from, :placed) when from in [:pending_payment, :expired],
    do: convert_holds(order)

  defp settle_holds(order, :pending_payment, to) when to in [:expired, :cancelled],
    do: release_holds(order)

  defp settle_holds(_order, _from, _to), do: {:ok, :untouched}

  defp convert_holds(order) do
    Enum.each(order.items, fn item ->
      Repo.update_all(limit_query(order, item),
        inc: [reserved_qty: -item.qty, sold_qty: item.qty]
      )
    end)

    {:ok, :converted}
  end

  defp release_holds(order) do
    Enum.each(order.items, fn item ->
      Repo.update_all(limit_query(order, item), inc: [reserved_qty: -item.qty])
    end)

    {:ok, :released}
  end

  # Zero-row match (no limit row exists — an unlimited item never had a
  # hold to begin with) is a correct, silent no-op, not an error.
  defp limit_query(order, item) do
    from(l in DailyItemLimit,
      where:
        l.item_id == ^item.menu_item_id and l.venue_id == ^order.venue_id and
          l.date == ^order.business_date
    )
  end

  ## Telemetry (code-standards.md — exact names, never invented ad hoc)

  defp emit_telemetry(scope, order, from, to) do
    :telemetry.execute(
      [:tabletap, :order, :transition],
      %{},
      %{order_id: order.id, from: from, to: to, actor_role: scope.role}
    )

    if to == :placed do
      :telemetry.execute(
        [:tabletap, :order, :placed],
        %{},
        %{
          org_id: order.org_id,
          venue_id: order.venue_id,
          order_id: order.id,
          total: order.total,
          kind: order.kind
        }
      )
    end

    if to == :served do
      :telemetry.execute(
        [:tabletap, :order, :served],
        %{},
        %{order_id: order.id, accept_to_served_ms: accept_to_served_ms(order)}
      )
    end
  end

  defp accept_to_served_ms(%Order{accepted_at: nil}), do: nil

  defp accept_to_served_ms(%Order{accepted_at: accepted_at, served_at: served_at}) do
    DateTime.diff(served_at, accepted_at, :millisecond)
  end

  defp broadcast(order) do
    Phoenix.PubSub.broadcast(Tabletap.PubSub, "order:#{order.id}", :order_updated)
    # architecture.md "Real-time Topology" — the KDS board, manager live
    # floor view, and POS all watch every transition at a venue, not
    # just this one order's own tracker page.
    Phoenix.PubSub.broadcast(Tabletap.PubSub, "venue:#{order.venue_id}:orders", :order_updated)
  end
end

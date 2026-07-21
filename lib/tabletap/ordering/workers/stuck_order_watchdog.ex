defmodule Tabletap.Ordering.Workers.StuckOrderWatchdog do
  @moduledoc """
  Proactive alert for orders stalled in a non-terminal state past
  threshold (build-plan.md Feature 21 — "Oban cron sweep alerting
  managers on orders in a non-terminal state past thresholds").

  The threshold itself isn't new: `Analytics.delayed?/2` already flags
  the exact same bar (`Ordering.expected_prep_minutes/1`-based) for
  `Manager.DashboardLive`'s live `delayed_orders` alert tile — that only
  reaches a manager who has the dashboard open. This worker is the
  proactive **push** version of that same signal (design-qa.md's own
  Q25/Q49 already talk about "the stuck-order watchdog alerting the
  manager" as if this delivery already existed), reusing
  `Notifications.Workers.SendPush`'s manager/owner audience exactly like
  the low-stock alert does.

  Runs cross-tenant, once per scheduled tick — same shape as
  `SweepAbandonedCarts`/`ReconcilePendingPayments`: loop
  `Tenants.list_org_ids/0` + `Repo.put_org_id/1`, then one plain
  `Order` query per org (never `skip_org_id: true` — `Ordering` isn't on
  that exception list, code-standards.md "Tenancy Rules").

  Each stuck order gets **at most one** alert ever, via Oban's own
  `unique` option keyed on the order's id — a manager who's already been
  told doesn't get pinged again every tick the order stays stuck. Two
  non-obvious things about `unique`, both caught by tests that asserted
  the actual enqueued job rather than just "something got returned":
  `keys:` must be **atoms** (`[:order_id]`) even though this worker's
  own `args` map uses string keys throughout, like every other worker in
  this codebase — Oban's changeset validation rejects string keys
  outright. And `fields: [:worker, :args]` is deliberate, not the more
  obvious `[:args]` alone: `AssignWaiter`'s own job args also carry
  `order_id`/`org_id`, so without `:worker` in the comparison Oban
  considers a brand-new `SendPush` insert a "conflict" against an
  unrelated `AssignWaiter` job that merely happens to share the same
  order id.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias Tabletap.Notifications.Workers.SendPush
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Order
  alias Tabletap.{Repo, Tenants}

  @handoff_statuses [:placed, :accepted, :preparing, :ready]

  @impl Oban.Worker
  def perform(_job) do
    total =
      Tenants.list_org_ids()
      |> Enum.reduce(0, fn org_id, acc ->
        Repo.put_org_id(org_id)
        acc + sweep_org(org_id)
      end)

    :telemetry.execute([:tabletap, :ordering, :stuck_orders_alerted], %{count: total}, %{})

    :ok
  end

  defp sweep_org(org_id) do
    now = DateTime.utc_now()

    from(o in Order,
      where: o.status in ^@handoff_statuses and not is_nil(o.placed_at),
      preload: [items: :menu_item]
    )
    |> Repo.all()
    |> Enum.filter(&stuck?(&1, now))
    |> Enum.count(&enqueue_alert(&1, org_id))
  end

  defp stuck?(order, now) do
    DateTime.diff(now, order.placed_at, :second) > Ordering.expected_prep_minutes(order) * 60
  end

  # `unique` means a still-stuck order from an earlier tick returns its
  # existing job (`conflict?: true`) rather than a fresh one — only a
  # genuinely new insert counts toward the telemetry total below.
  defp enqueue_alert(order, org_id) do
    result =
      %{
        "type" => "stuck_order",
        "order_id" => order.id,
        "org_id" => org_id,
        "venue_id" => order.venue_id,
        "title" => "Order running late",
        "body" => "Order ##{order.number} is past its expected time",
        "url" => "/orders"
      }
      |> SendPush.new(unique: [fields: [:worker, :args], keys: [:order_id], period: :infinity])
      |> Oban.insert()

    match?({:ok, %{conflict?: false}}, result)
  end
end

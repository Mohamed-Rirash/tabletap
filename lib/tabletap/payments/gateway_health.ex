defmodule Tabletap.Payments.GatewayHealth do
  @moduledoc """
  Tracks whether the wallet payment gateway looks reachable
  (build-plan.md Feature 21 — "degradation banners: payment gateway
  unreachable, wallet payments paused, cash keeps working").

  A **consecutive-failure counter**, not a single-miss trip: one slow
  request or one declined card shouldn't flip a banner on for every
  manager. `Payments.resolve_charge_result/2` calls `record_success/0`
  on a real gateway response (approved, declined, or any definitive
  business-level outcome — the gateway answered, it's up) and
  `record_failure/0` only for a genuine connectivity-shaped outcome
  (`:timeout`, or an ambiguous dropped-connection/HTTP-level error).

  ETS-backed, in-process — same shape and the same accepted looseness
  `TabletapWeb.RateLimiter` already documents: not distributed, so on a
  multi-node deploy each node tracks its own view of gateway health.
  Worst case, two nodes briefly disagree on whether to show the banner;
  it self-heals on each node's own next charge attempt/reconciliation
  poll, and this is a courtesy banner, not a payment-correctness
  mechanism (the poller/idempotent resolution path doesn't depend on it
  at all).
  """
  use GenServer

  @table __MODULE__
  @degraded_after 3

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "A real gateway response came back — resets the streak."
  def record_success, do: :ets.insert(@table, {:consecutive_failures, 0})

  @doc "A connectivity-shaped failure (timeout, dropped connection) — extends the streak."
  def record_failure do
    :ets.update_counter(@table, :consecutive_failures, {2, 1}, {:consecutive_failures, 0})
    :ok
  end

  @doc "Whether the gateway looks degraded — #{@degraded_after}+ consecutive connectivity failures."
  def degraded? do
    case :ets.lookup(@table, :consecutive_failures) do
      [{:consecutive_failures, count}] -> count >= @degraded_after
      [] -> false
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end

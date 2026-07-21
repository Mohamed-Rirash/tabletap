defmodule TabletapWeb.TelemetryTest do
  @moduledoc """
  `dispatch_oban_queue_depth/0` (build-plan.md Feature 21's alerting) —
  DB-backed via the sandboxed `Tabletap.ObanRepo`, so (unlike the
  process-independent ETS state in `Payments.GatewayHealth`) this is
  safe under `async: true`: each test only sees jobs its own sandboxed
  transaction inserted.
  """
  use Tabletap.DataCase, async: true

  alias Tabletap.Ordering.Workers.SweepAbandonedCarts
  alias TabletapWeb.Telemetry

  defp attach_and_capture(event) do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {event, ref},
      event,
      fn ^event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, ref, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({event, ref}) end)

    ref
  end

  test "emits one [:tabletap, :oban, :queue_depth] event per queue/state combination" do
    ref = attach_and_capture([:tabletap, :oban, :queue_depth])

    {:ok, _job1} = SweepAbandonedCarts.new(%{}) |> Oban.insert()
    {:ok, _job2} = SweepAbandonedCarts.new(%{}) |> Oban.insert()

    Telemetry.dispatch_oban_queue_depth()

    assert_receive {:telemetry_event, ^ref, %{count: count},
                    %{queue: "default", state: "available"}}

    assert count >= 2
  end

  test "is a no-op, not a crash, when there's nothing to report" do
    # A fresh sandboxed transaction with no jobs inserted at all.
    assert Telemetry.dispatch_oban_queue_depth() == :ok
  end
end

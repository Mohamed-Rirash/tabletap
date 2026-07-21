defmodule TabletapWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("tabletap.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("tabletap.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("tabletap.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("tabletap.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("tabletap.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Payment confirmation lag (build-plan.md Feature 21's "webhook-lag
      # p95" alert) — `Payments.resolve_charge_result/2`/`confirm_approved/3`/
      # `confirm_failed/2` tag every real (non-idempotent) confirmation
      # by which channel resolved it. A `:poller`-tagged p95 climbing
      # means the immediate charge response and the webhook callback are
      # both missing more often than usual.
      summary("tabletap.payment.confirmed.lag_ms", tags: [:via]),

      # Oban queue depth (build-plan.md Feature 21) — see
      # `dispatch_oban_queue_depth/0` below, invoked by the poller.
      last_value("tabletap.oban.queue_depth.count", tags: [:queue, :state])
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {TabletapWeb, :count_users, []}

      # Off in test (config/test.exs) — Oban itself runs `testing: :manual`
      # there, so queue-depth telemetry is meaningless, and the poller's
      # own background process was never granted a Sandbox connection
      # (`Ecto.Adapters.SQL.Sandbox` requires an explicit checkout/allow
      # per process), which would otherwise log a harmless but noisy
      # `DBConnection.OwnershipError` every 10s during the whole suite.
      if Application.get_env(:tabletap, :poll_oban_queue_depth, true) do
        {__MODULE__, :dispatch_oban_queue_depth, []}
      end
    ]
    |> Enum.filter(& &1)
  end

  # `:telemetry_poller` fires its first measurement immediately at
  # startup, before `Tabletap.ObanRepo` (started after this supervisor
  # in `Tabletap.Application`'s own child order) is necessarily up yet —
  # a no-op here just means the next 10s tick picks it up instead.
  @doc false
  def dispatch_oban_queue_depth do
    import Ecto.Query

    if Process.whereis(Tabletap.ObanRepo) do
      Tabletap.ObanRepo.all(
        from(j in Oban.Job,
          where: j.state in ["available", "executing"],
          group_by: [j.queue, j.state],
          select: {j.queue, j.state, count(j.id)}
        )
      )
      |> Enum.each(fn {queue, state, count} ->
        :telemetry.execute(
          [:tabletap, :oban, :queue_depth],
          %{count: count},
          %{queue: queue, state: state}
        )
      end)
    end
  end
end

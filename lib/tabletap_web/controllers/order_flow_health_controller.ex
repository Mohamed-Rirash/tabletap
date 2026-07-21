defmodule TabletapWeb.OrderFlowHealthController do
  @moduledoc """
  Synthetic order-flow health check (build-plan.md Feature 21) — for an
  external uptime monitor, distinct from the bare liveness `/healthz`
  probe: this exercises a real DB round-trip through the actual
  QR→menu code path (`Tabletap.Ops.check_order_flow/0`) against a
  dedicated synthetic venue, never a real tenant's.
  """
  use TabletapWeb, :controller

  alias Tabletap.Ops

  def show(conn, _params) do
    case Ops.check_order_flow() do
      :ok -> send_resp(conn, 200, "ok")
      {:error, reason} -> send_resp(conn, 503, "order-flow check failed: #{inspect(reason)}")
    end
  end
end

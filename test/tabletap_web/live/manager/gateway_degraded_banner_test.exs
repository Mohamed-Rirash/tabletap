defmodule TabletapWeb.Manager.GatewayDegradedBannerTest do
  @moduledoc """
  `<.gateway_degraded_banner>` (build-plan.md Feature 21), rendered by
  `Layouts.manager` on every back-office page. `async: false` and its
  own file — `Payments.GatewayHealth` is shared, process-independent
  ETS state, racy to assert on on alongside other `async: true` tests
  that also call `Payments.resolve_charge_result/2`.
  """
  use TabletapWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tabletap.Payments.GatewayHealth

  setup do
    GatewayHealth.record_success()
    on_exit(fn -> GatewayHealth.record_success() end)
    :ok
  end

  setup :register_and_log_in_owner

  test "hidden when the gateway looks healthy", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/dashboard")

    refute html =~ "Wallet payments look unreachable"
  end

  test "shown on every manager surface once the gateway looks degraded", %{conn: conn} do
    GatewayHealth.record_failure()
    GatewayHealth.record_failure()
    GatewayHealth.record_failure()

    {:ok, _lv, html} = live(conn, ~p"/dashboard")
    assert html =~ "Wallet payments look unreachable"
  end
end

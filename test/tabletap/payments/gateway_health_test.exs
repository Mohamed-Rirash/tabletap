defmodule Tabletap.Payments.GatewayHealthTest do
  @moduledoc """
  A consecutive-failure counter, not a single-miss trip (build-plan.md
  Feature 21's degradation banner) — `async: false` since this is
  shared, process-independent ETS state (the real `GatewayHealth`
  GenServer, already started under the application supervisor).
  """
  use ExUnit.Case, async: false

  alias Tabletap.Payments.GatewayHealth

  setup do
    GatewayHealth.record_success()
    :ok
  end

  test "starts (and resets to) not degraded" do
    refute GatewayHealth.degraded?()
  end

  test "one or two consecutive failures alone don't flip it degraded" do
    GatewayHealth.record_failure()
    refute GatewayHealth.degraded?()

    GatewayHealth.record_failure()
    refute GatewayHealth.degraded?()
  end

  test "three consecutive failures flips it degraded" do
    GatewayHealth.record_failure()
    GatewayHealth.record_failure()
    GatewayHealth.record_failure()

    assert GatewayHealth.degraded?()
  end

  test "a success in between resets the streak" do
    GatewayHealth.record_failure()
    GatewayHealth.record_failure()
    GatewayHealth.record_success()
    GatewayHealth.record_failure()
    GatewayHealth.record_failure()

    refute GatewayHealth.degraded?()
  end

  test "a success after being degraded clears it" do
    GatewayHealth.record_failure()
    GatewayHealth.record_failure()
    GatewayHealth.record_failure()
    assert GatewayHealth.degraded?()

    GatewayHealth.record_success()
    refute GatewayHealth.degraded?()
  end
end

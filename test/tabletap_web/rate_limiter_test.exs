defmodule TabletapWeb.RateLimiterTest do
  # async: false — the limiter is a single named ETS table shared by the
  # whole test run; concurrent tests would trip each other's windows.
  use ExUnit.Case, async: false

  alias TabletapWeb.RateLimiter

  test "allows requests under the limit and blocks once the limit is hit" do
    key = {:test, System.unique_integer()}

    results = for _ <- 1..5, do: RateLimiter.check(key)
    assert results == [:ok, :ok, :ok, :ok, :ok]

    assert RateLimiter.check(key) == :rate_limited
  end

  test "different keys have independent budgets" do
    key_a = {:test, System.unique_integer()}
    key_b = {:test, System.unique_integer()}

    for _ <- 1..5, do: RateLimiter.check(key_a)
    assert RateLimiter.check(key_a) == :rate_limited

    assert RateLimiter.check(key_b) == :ok
  end

  test "check/2's :max and :window_ms opts override the default budget (build-plan.md Feature 22)" do
    key = {:test, System.unique_integer()}

    results = for _ <- 1..10, do: RateLimiter.check(key, max: 10)
    assert results == List.duplicate(:ok, 10)

    assert RateLimiter.check(key, max: 10) == :rate_limited
  end

  test "client_ip_from_conn/1 prefers x-forwarded-for over the raw peer address" do
    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Conn.put_req_header("x-forwarded-for", "203.0.113.7, 10.0.0.1")

    assert RateLimiter.client_ip_from_conn(conn) == "203.0.113.7"
  end

  test "client_ip_from_conn/1 falls back to remote_ip with no proxy header" do
    conn = %{Plug.Test.conn(:get, "/") | remote_ip: {127, 0, 0, 1}}

    assert RateLimiter.client_ip_from_conn(conn) == "127.0.0.1"
  end
end

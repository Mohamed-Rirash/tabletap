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
end

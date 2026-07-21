defmodule TabletapWeb.Public.TableControllerRateLimitTest do
  @moduledoc """
  `GET /t/:qr_token` rate limiting (build-plan.md Feature 22) — `async:
  false`, same reasoning as `RateLimiterTest`: the limiter is a single
  shared ETS table. Each test uses its own `x-forwarded-for` IP so it
  never collides with the many other, unrelated `async: true` tests
  that hit this same route using the default test-conn IP.
  """
  use TabletapWeb.ConnCase, async: false

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Repo

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    table = table_fixture(%Scope{org: org, venue: venue}, %{"number" => "1"})
    %{table: table}
  end

  defp with_ip(conn, ip), do: Plug.Conn.put_req_header(conn, "x-forwarded-for", ip)

  test "30 scans from the same IP succeed, the 31st is rate-limited", %{conn: conn, table: table} do
    ip = "203.0.113.#{System.unique_integer([:positive])}"
    conn = with_ip(conn, ip)

    for _ <- 1..30 do
      resp = get(conn, ~p"/t/#{table.qr_token}")
      assert redirected_to(resp) =~ "/menu"
    end

    resp = get(conn, ~p"/t/#{table.qr_token}")
    assert resp.status == 429
    assert html_response(resp, 429) =~ "Too many scans"
  end

  test "a different IP has its own, unaffected budget", %{conn: conn, table: table} do
    ip_a = "203.0.113.#{System.unique_integer([:positive])}"
    ip_b = "203.0.113.#{System.unique_integer([:positive])}"

    for _ <- 1..30, do: get(with_ip(conn, ip_a), ~p"/t/#{table.qr_token}")

    resp = get(with_ip(conn, ip_b), ~p"/t/#{table.qr_token}")
    assert redirected_to(resp) =~ "/menu"
  end
end

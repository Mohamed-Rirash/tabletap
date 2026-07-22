defmodule TabletapWeb.CorsPlugTest do
  @moduledoc """
  build-plan.md Feature 24 — CORS support for `/api/v1`, needed
  because a real native app never sends an `Origin` header (never
  subject to CORS), but Expo's web target — this sandbox's own
  substitute for a physical device/emulator — is a real browser and
  was genuinely blocked by the missing headers until this landed.
  """
  use TabletapWeb.ConnCase, async: true

  test "an OPTIONS preflight to an /api/v1 route gets CORS headers and a 204, never reaching the router",
       %{conn: conn} do
    conn =
      conn
      |> put_req_header("origin", "http://localhost:8090")
      |> put_req_header("access-control-request-method", "GET")
      |> options(~p"/api/v1/venues/does-not-matter/menu")

    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    assert get_resp_header(conn, "access-control-allow-methods") == ["GET, POST, DELETE, OPTIONS"]

    assert get_resp_header(conn, "access-control-allow-headers") == [
             "authorization, content-type"
           ]
  end

  test "a real /api/v1 request also gets the CORS headers", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/venues/does-not-exist/menu")

    assert conn.status == 404
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "a non-API route (the marketing home page) gets no CORS headers", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert get_resp_header(conn, "access-control-allow-origin") == []
  end
end

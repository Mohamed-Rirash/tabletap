defmodule TabletapWeb.HealthControllerTest do
  use TabletapWeb.ConnCase, async: true

  test "GET /healthz returns 200", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert conn.status == 200
    assert conn.resp_body == "ok"
  end
end

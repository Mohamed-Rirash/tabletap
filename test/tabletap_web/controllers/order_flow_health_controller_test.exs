defmodule TabletapWeb.OrderFlowHealthControllerTest do
  use TabletapWeb.ConnCase, async: true

  test "GET /healthz/order-flow returns 200 (creating the synthetic fixture on first hit)", %{
    conn: conn
  } do
    conn = get(conn, ~p"/healthz/order-flow")
    assert conn.status == 200
    assert conn.resp_body == "ok"
  end
end

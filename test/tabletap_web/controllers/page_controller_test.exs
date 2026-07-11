defmodule TabletapWeb.PageControllerTest do
  use TabletapWeb.ConnCase

  test "GET / renders the marketing home page", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ "Scan the table. Order."
    assert response =~ "Start free — 14 days, no card"
    assert response =~ ~p"/users/register"
  end
end

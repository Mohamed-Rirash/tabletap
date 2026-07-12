defmodule TabletapWeb.Public.TableControllerTest do
  use TabletapWeb.ConnCase, async: true

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Repo

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    table = table_fixture(%Scope{org: org, venue: venue}, %{"number" => "12"})
    %{org: org, venue: venue, table: table}
  end

  test "resolves a token, stores the table in the session, and redirects to the menu",
       %{conn: conn, venue: venue, table: table} do
    conn = get(conn, ~p"/t/#{table.qr_token}")

    assert redirected_to(conn) == ~p"/venues/#{venue.slug}/menu"
    assert get_session(conn, :table_id) == table.id
  end

  test "an unknown token renders an honest not-found page (never the marketing homepage)",
       %{conn: conn} do
    conn = get(conn, ~p"/t/not-a-real-token")

    assert conn.status == 404
    assert html_response(conn, 404) =~ "isn&#39;t active"
    refute get_session(conn, :table_id)
  end
end

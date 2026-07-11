defmodule TabletapWeb.Manager.DashboardLiveTest do
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/dashboard")
    end

    test "redirects away a logged-in user with no staff membership", %{conn: conn} do
      user = Tabletap.AccountsFixtures.user_fixture()
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/dashboard")
    end
  end

  describe "as an owner" do
    setup :register_and_log_in_owner

    test "shows the venue, org, and role", %{conn: conn, org: org, venue: venue} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ venue.name
      assert html =~ org.name
      assert html =~ "Owner"
      assert html =~ "Your venue is set up"
    end

    test "renders TableTap's own chrome, not the Phoenix generator's placeholder header",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "TableTap"
      refute html =~ "phoenixframework.org"
      refute html =~ "github.com/phoenixframework"
      refute html =~ "Get Started"
    end

    test "does not show a 'Live' badge — nothing on this page is live yet", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "badge-primary"
    end

    test "shows a trial countdown badge", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "days left in trial"
    end

    test "hides the venue switcher with only one venue", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ ~s(name="venue_id")
    end

    test "shows the venue switcher with more than one venue", %{
      conn: conn,
      org: org,
      venue: venue
    } do
      second_venue = venue_fixture(org)

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(name="venue_id")
      assert html =~ venue.name
      assert html =~ second_venue.name
    end
  end

  describe "switching venues" do
    setup :register_and_log_in_owner

    test "moves the current venue and persists it in the session", %{
      conn: conn,
      org: org,
      venue: first_venue
    } do
      second_venue = venue_fixture(org)

      conn = post(conn, ~p"/venues/switch", venue_id: second_venue.id)
      assert redirected_to(conn) == ~p"/dashboard"

      conn = get(conn, ~p"/dashboard")
      html = html_response(conn, 200)
      assert html =~ second_venue.name
      refute html =~ ~s(<h1 class="text-2xl font-bold">#{first_venue.name}</h1>)
    end

    test "refuses a venue from a different org", %{conn: conn} do
      %{venue: other_venue} = org_fixture()

      conn = post(conn, ~p"/venues/switch", venue_id: other_venue.id)

      assert redirected_to(conn) == ~p"/dashboard"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "isn't part of your organization"
    end
  end
end

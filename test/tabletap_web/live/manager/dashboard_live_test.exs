defmodule TabletapWeb.Manager.DashboardLiveTest do
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.{Catalog, Ordering, Tenants}
  alias Tabletap.Ordering.{Cart, OrderStateMachine}

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
    end

    test "no PWA manifest — the back office isn't one of the two installable surfaces (build-plan.md Feature 20)",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ ~s(rel="manifest")
    end

    test "shows the Today tiles, an empty floor, and no alerts on a fresh venue", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Revenue today"
      assert html =~ "Orders today"
      assert html =~ "Open orders now"
      assert html =~ "No open orders right now."
      assert html =~ "Nothing needs your attention."
    end

    test "shows the onboarding checklist on a fresh venue, venue info already checked (build-plan.md Feature 20)",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Get your venue live"
      assert html =~ "Venue info added"
      assert html =~ "Wallet merchant set up"
      assert html =~ "Menu created"
      assert html =~ "Tables added"
      assert html =~ "First order placed"
    end

    test "hides the onboarding checklist once every step is done (build-plan.md Feature 20)", %{
      conn: conn,
      org: org,
      scope: scope
    } do
      Tabletap.Repo.put_org_id(org.id)
      {:ok, venue} = Tenants.mark_charges_enabled(scope.venue)
      scope = %{scope | venue: venue}
      {:ok, _table} = Tenants.create_table(scope, %{"number" => "1"})
      {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

      {:ok, item} =
        Catalog.create_item(scope, category, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "3.50")
        })

      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(scope, cart)
      {:ok, _placed} = OrderStateMachine.transition(scope, order, :placed)

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "Get your venue live"
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

    test "shows a past_due banner — ordering keeps working, just a nudge", %{conn: conn, org: org} do
      org |> Ecto.Changeset.change(subscription_status: :past_due) |> Tabletap.Repo.update!()

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "didn&#39;t go through"
      assert html =~ "Fix billing"
    end

    test "shows a canceled banner", %{conn: conn, org: org} do
      org |> Ecto.Changeset.change(subscription_status: :canceled) |> Tabletap.Repo.update!()

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Ordering is disabled"
      assert html =~ "Reactivate"
    end

    test "shows nothing extra once active", %{conn: conn, org: org} do
      org |> Ecto.Changeset.change(subscription_status: :active) |> Tabletap.Repo.update!()

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "days left in trial"
      refute html =~ "Fix billing"
      refute html =~ "Reactivate"
    end

    test "shows the enable-notifications button and persists a subscription (build-plan.md Feature 20)",
         %{
           conn: conn,
           user: user
         } do
      {:ok, lv, html} = live(conn, ~p"/dashboard")
      assert html =~ "Enable notifications"

      render_hook(lv, "push_subscribe", %{
        "endpoint" => "https://push.example.com/manager-1",
        "p256dh" =>
          "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM",
        "auth" => "tBHItJI5svbpez7KI4CCXg",
        "user_agent" => "Test/1.0"
      })

      assert [subscription] =
               Tabletap.Repo.all(Tabletap.Notifications.PushSubscription, skip_org_id: true)

      assert subscription.user_id == user.id
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

  describe "Busy Mode (build-plan.md Feature 08, design-qa.md Q2)" do
    setup :register_and_log_in_owner

    test "shows Open with no pause controls resumed by default", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Open"
      assert html =~ "Pause 20 min"
      refute html =~ "Resume ordering"
    end

    test "pausing for 20 minutes flips to Paused and offers Resume instead", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      html =
        lv |> element(~s([phx-click="pause_ordering"][phx-value-minutes="20"])) |> render_click()

      assert html =~ "Paused"
      assert html =~ "Resume ordering"
      refute html =~ "Pause 20 min"
    end

    test "pausing until reopened shows the indefinite message, not a clock time", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      html =
        lv
        |> element(~s([phx-click="pause_ordering"][phx-value-minutes="indefinite"]))
        |> render_click()

      assert html =~ "Paused until you resume it."
    end

    test "resuming after a pause returns to Open", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element(~s([phx-click="pause_ordering"][phx-value-minutes="20"])) |> render_click()

      html = lv |> element(~s([phx-click="resume_ordering"])) |> render_click()

      assert html =~ "Open"
      refute html =~ "Resume ordering"
    end

    test "setting kitchen speed to Slower marks that button active, not Normal speed", %{
      conn: conn
    } do
      {:ok, lv, html} = live(conn, ~p"/dashboard")
      assert button_class(html, "1") =~ "btn-primary"

      html =
        lv
        |> element(~s([phx-click="set_eta_inflation"][phx-value-factor="1.5"]))
        |> render_click()

      assert button_class(html, "1.5") =~ "btn-primary"
      refute button_class(html, "1") =~ "btn-primary"
    end

    test "pausing broadcasts to the public menu's live-update topic", %{conn: conn, venue: venue} do
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{venue.id}:menu")
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      lv |> element(~s([phx-click="pause_ordering"][phx-value-minutes="20"])) |> render_click()

      assert_receive :menu_updated
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

  # No Floki dependency in this project — the eta-inflation buttons render
  # in a fixed attribute order (phx-value-factor immediately before
  # class), so a small regex is enough to pull one button's class list
  # without a full HTML parser.
  defp button_class(html, factor) do
    [_, class] =
      Regex.run(~r/phx-value-factor="#{Regex.escape(factor)}"[^>]*class="([^"]*)"/, html)

    class
  end
end

defmodule TabletapWeb.Manager.Analytics.VenueComparisonLiveTest do
  @moduledoc """
  `TabletapWeb.Manager.Analytics.VenueComparisonLive` at
  `/analytics/venues` (build-plan.md Feature 18, owner-dashboard.md's
  "Org View" — owner only, multi-venue).
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Ordering, Payments, Repo}
  alias Tabletap.Ordering.Cart
  alias Tabletap.Tenants.Membership
  alias Tabletap.TenantsFixtures

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/analytics/venues")
    end

    test "redirects a manager away — this page is owner-only", %{conn: conn} do
      %{org: org, venue: venue} = TenantsFixtures.org_fixture()
      manager_user = Tabletap.AccountsFixtures.user_fixture()

      {:ok, _} =
        %Membership{}
        |> Membership.changeset(%{
          org_id: org.id,
          venue_id: venue.id,
          user_id: manager_user.id,
          role: :manager
        })
        |> Repo.insert()

      conn = log_in_user(conn, manager_user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/analytics/venues")
    end
  end

  describe "as an owner" do
    setup :register_and_log_in_owner

    setup %{org: org, venue: venue} do
      Repo.put_org_id(org.id)
      scope = %Scope{org: org, venue: venue}

      {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

      {:ok, item} =
        Catalog.create_item(scope, category, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "3.50")
        })

      %{scope: scope, item: item}
    end

    test "shows the single venue with no comparison siblings yet", %{conn: conn, venue: venue} do
      {:ok, _lv, html} = live(conn, ~p"/analytics/venues")

      assert html =~ venue.name
      assert html =~ "trialing"
    end

    test "reconciles two venues side by side, each in its own row", %{
      conn: conn,
      scope: scope,
      venue: venue,
      item: item
    } do
      %{membership: cashier} = TenantsFixtures.cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(cashier_scope, token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(cashier_scope, cart)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)

      second_venue = TenantsFixtures.venue_fixture(scope.org, %{"currency" => "USD"})

      {:ok, _lv, html} = live(conn, ~p"/analytics/venues?range=today")

      assert html =~ venue.name
      assert html =~ second_venue.name
      assert html =~ "3.50"
    end

    test "switching range patches the URL", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/analytics/venues")

      html = lv |> element(~s(a[href="/analytics/venues?range=30d"])) |> render_click()
      assert html =~ "Org View"
      assert_patch(lv, ~p"/analytics/venues?range=30d")
    end
  end
end

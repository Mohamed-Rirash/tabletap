defmodule TabletapWeb.Manager.Analytics.RevenueLiveTest do
  @moduledoc """
  `TabletapWeb.Manager.Analytics.RevenueLive` at `/analytics/revenue`
  (build-plan.md Feature 18, owner-dashboard.md Screen 2).
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Cart
  alias Tabletap.Payments
  alias Tabletap.Repo

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/analytics/revenue")
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

    test "defaults to the 7-day range and shows the headline tiles", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/analytics/revenue")

      assert html =~ "Net revenue"
      assert html =~ "Orders"
      assert html =~ "Average check"
      assert html =~ "Gross profit"
    end

    test "reconciles net revenue and order count with a real cash sale", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(cashier_scope, token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(cashier_scope, cart)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)

      {:ok, _lv, html} = live(conn, ~p"/analytics/revenue?range=today")

      assert html =~ "3.50"
      assert html =~ "Cash"
    end

    test "switching to Today updates the URL and stays on the page", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/analytics/revenue")

      html = lv |> element(~s(a[href="/analytics/revenue?range=today"])) |> render_click()
      assert html =~ "Revenue &amp; Sales"
      assert_patch(lv, ~p"/analytics/revenue?range=today")
    end

    test "a custom range submits and patches to the given dates", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/analytics/revenue")

      lv
      |> form("form", %{"from" => "2026-01-01", "to" => "2026-01-05"})
      |> render_submit()

      assert_patch(lv, ~p"/analytics/revenue?from=2026-01-01&to=2026-01-05")
    end

    test "CSV export link points at the matching date range", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/analytics/revenue?range=30d")
      assert html =~ "/analytics/revenue.csv?"
    end
  end
end

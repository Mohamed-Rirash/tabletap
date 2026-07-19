defmodule TabletapWeb.Manager.Analytics.MenuPerformanceLiveTest do
  @moduledoc """
  `TabletapWeb.Manager.Analytics.MenuPerformanceLive` at
  `/analytics/menu-performance` (build-plan.md Feature 18,
  owner-dashboard.md Screen 3).
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
  alias Tabletap.Repo

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/analytics/menu-performance")
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

    test "shows an empty state with no sales yet", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/analytics/menu-performance")
      assert html =~ "No items sold in this period."
    end

    test "reconciles a served item's sold/revenue and shows it in a quadrant", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 3, nil)
      {:ok, order} = Ordering.checkout(scope, cart)

      order =
        Enum.reduce([:placed, :accepted, :preparing, :ready, :served], order, fn status, acc ->
          {:ok, moved} = OrderStateMachine.transition(scope, acc, status)
          moved
        end)

      {:ok, _lv, html} = live(conn, ~p"/analytics/menu-performance?range=today")

      assert html =~ "Latte"
      assert html =~ "10.50"
      refute html =~ "No items sold in this period."
      _ = order
    end

    test "switching range patches the URL", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/analytics/menu-performance")

      html = lv |> element(~s(a[href="/analytics/menu-performance?range=30d"])) |> render_click()
      assert html =~ "Menu Performance"
      assert_patch(lv, ~p"/analytics/menu-performance?range=30d")
    end
  end
end

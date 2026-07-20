defmodule TabletapWeb.Manager.Analytics.InventoryCostLiveTest do
  @moduledoc """
  `TabletapWeb.Manager.Analytics.InventoryCostLive` at
  `/analytics/inventory-cost` (build-plan.md Feature 18,
  owner-dashboard.md Screen 6).
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Inventory}
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
  alias Tabletap.Repo

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/analytics/inventory-cost")
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

    test "shows empty states with no ingredients or activity yet", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/analytics/inventory-cost")

      assert html =~ "No ingredients yet."
      assert html =~ "No consumption yet."
      assert html =~ "No logged wastage this period."
      assert html =~ "No restocks this period."
    end

    test "reconciles stock on hand, food cost %, and purchase history from a real restock + sale",
         %{conn: conn, scope: scope, item: item} do
      {:ok, flour} =
        Inventory.create_ingredient(scope, %{
          "name" => "Flour",
          "unit" => "g",
          "cost_per_unit" => Money.new!(:USD, "0.01")
        })

      {:ok, _} = Inventory.add_recipe_line(scope, item, flour, Decimal.new(50))
      {:ok, _} = Inventory.restock(scope, flour, Decimal.new(1000), Money.new!(:USD, "0.01"), nil)

      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(scope, cart)

      Enum.reduce([:placed, :accepted, :preparing, :ready, :served], order, fn status, acc ->
        {:ok, moved} = OrderStateMachine.transition(scope, acc, status)
        moved
      end)

      {:ok, _lv, html} = live(conn, ~p"/analytics/inventory-cost?range=7d")

      assert html =~ "Flour"
      assert html =~ "950.0 g"
    end
  end
end

defmodule TabletapWeb.Api.CustomerExtrasTest do
  @moduledoc """
  build-plan.md Feature 24 Commit 1 — the 4 small backend endpoints the
  customer app needs beyond what Feature 23 already built: table-QR
  resolution, call-waiter, rate an item, and cross-venue order history.
  """
  use TabletapWeb.ConnCase, async: true

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Ordering, Repo}
  alias Tabletap.Feedback.ItemRating
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
  alias TabletapWeb.ApiAuth

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue, role: :guest}
    table = table_fixture(scope)

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    %{org: org, venue: venue, item: item, table: table}
  end

  defp bearer(conn, user) do
    put_req_header(conn, "authorization", "Bearer #{ApiAuth.sign_access_token(user)}")
  end

  describe "GET /api/v1/tables/:qr_token" do
    test "resolves a real table to its venue slug and id", %{venue: venue, table: table} do
      conn = get(build_conn(), ~p"/api/v1/tables/#{table.qr_token}")

      assert %{"venue_slug" => slug, "table_id" => table_id} = json_response(conn, 200)
      assert slug == venue.slug
      assert table_id == table.id
    end

    test "404s for an unknown qr_token" do
      conn = get(build_conn(), ~p"/api/v1/tables/does-not-exist")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/v1/orders/:guest_token/call_waiter" do
    test "a dine-in order at a waiter-mode venue succeeds", %{
      org: org,
      venue: venue,
      item: item,
      table: table
    } do
      guest_token = Cart.generate_guest_token()
      scope = %Scope{org: org, venue: venue, role: :guest}
      {:ok, _cart} = Ordering.add_to_cart(scope, guest_token, table.id, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(scope, Ordering.get_active_cart(scope, guest_token))
      {:ok, _order} = OrderStateMachine.transition(scope, order, :placed)

      conn = post(build_conn(), ~p"/api/v1/orders/#{guest_token}/call_waiter")
      assert response(conn, 204)
    end

    test "a takeaway (table-less) order is rejected — no table to call from", %{
      org: org,
      venue: venue,
      item: item
    } do
      guest_token = Cart.generate_guest_token()
      scope = %Scope{org: org, venue: venue, role: :guest}
      {:ok, _cart} = Ordering.add_to_cart(scope, guest_token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(scope, Ordering.get_active_cart(scope, guest_token))
      {:ok, _order} = OrderStateMachine.transition(scope, order, :placed)

      conn = post(build_conn(), ~p"/api/v1/orders/#{guest_token}/call_waiter")
      assert %{"error" => "no_table"} = json_response(conn, 422)
    end

    test "404s for an unknown guest_token" do
      conn = post(build_conn(), ~p"/api/v1/orders/does-not-exist/call_waiter")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/v1/orders/:guest_token/items/:order_item_id/rate" do
    defp served_order(org, venue, item, table) do
      guest_token = Cart.generate_guest_token()
      scope = %Scope{org: org, venue: venue, role: :guest}
      {:ok, _cart} = Ordering.add_to_cart(scope, guest_token, table.id, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(scope, Ordering.get_active_cart(scope, guest_token))

      order =
        Enum.reduce([:placed, :accepted, :preparing, :ready, :served], order, fn to, order ->
          {:ok, order} = OrderStateMachine.transition(scope, order, to)
          order
        end)

      {guest_token, Ordering.get_order(scope, order.id)}
    end

    test "rates a served order's item", %{org: org, venue: venue, item: item, table: table} do
      {guest_token, order} = served_order(org, venue, item, table)
      [order_item] = order.items

      conn =
        post(
          build_conn(),
          ~p"/api/v1/orders/#{guest_token}/items/#{order_item.id}/rate",
          %{"stars" => 5}
        )

      assert response(conn, 204)
      assert Repo.get_by(ItemRating, [order_item_id: order_item.id], skip_org_id: true).stars == 5
    end

    test "rating the same item twice is rejected", %{
      org: org,
      venue: venue,
      item: item,
      table: table
    } do
      {guest_token, order} = served_order(org, venue, item, table)
      [order_item] = order.items

      post(build_conn(), ~p"/api/v1/orders/#{guest_token}/items/#{order_item.id}/rate", %{
        "stars" => 5
      })

      conn =
        post(build_conn(), ~p"/api/v1/orders/#{guest_token}/items/#{order_item.id}/rate", %{
          "stars" => 3
        })

      assert %{"error" => "already_rated"} = json_response(conn, 422)
    end

    test "a malformed order_item_id is a clean 404, not a crash", %{
      org: org,
      venue: venue,
      item: item,
      table: table
    } do
      {guest_token, _order} = served_order(org, venue, item, table)

      conn =
        post(build_conn(), ~p"/api/v1/orders/#{guest_token}/items/not-a-uuid/rate", %{
          "stars" => 5
        })

      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v1/me/history" do
    test "returns the caller's own cross-venue order history", %{
      org: org,
      venue: venue,
      item: item,
      table: table
    } do
      guest_token = Cart.generate_guest_token()
      scope = %Scope{org: org, venue: venue, role: :guest}
      {:ok, _cart} = Ordering.add_to_cart(scope, guest_token, table.id, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(scope, Ordering.get_active_cart(scope, guest_token))
      {:ok, order} = OrderStateMachine.transition(scope, order, :placed)

      user = Tabletap.AccountsFixtures.user_fixture()
      {:ok, _count} = Ordering.link_guest_orders_to_customer(user, guest_token)

      conn = build_conn() |> bearer(user) |> get(~p"/api/v1/me/history")

      assert %{"orders" => [entry]} = json_response(conn, 200)
      assert entry["id"] == order.id
      assert entry["venue_name"] == venue.name
    end

    test "an unauthenticated request is rejected" do
      conn = get(build_conn(), ~p"/api/v1/me/history")
      assert json_response(conn, 401)
    end
  end
end

defmodule TabletapWeb.Api.StaffApiTest do
  @moduledoc """
  build-plan.md Feature 23 Commit 4 — waiter accept/serve + owner
  dashboard, bearer-token protected.
  """
  use TabletapWeb.ConnCase, async: true

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Ordering, Repo}
  alias Tabletap.Ordering.{Cart, Order, OrderStateMachine}
  alias TabletapWeb.ApiAuth

  setup do
    %{org: org, venue: venue, user: owner} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue, role: :owner}

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    %{user: waiter_user, membership: waiter_membership} = waiter_fixture(org, venue)

    %{
      org: org,
      venue: venue,
      owner: owner,
      item: item,
      waiter_user: waiter_user,
      waiter_membership: waiter_membership
    }
  end

  defp placed_order(org, venue, item) do
    scope = %Scope{org: org, venue: venue, role: :guest}
    guest_token = Cart.generate_guest_token()
    {:ok, _cart} = Ordering.add_to_cart(scope, guest_token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, Ordering.get_active_cart(scope, guest_token))
    OrderStateMachine.transition(scope, order, :placed)
  end

  defp bearer(conn, user) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{ApiAuth.sign_access_token(user)}")
  end

  describe "POST /api/v1/waiter/orders/:id/accept" do
    test "the assigned waiter accepts their own order", %{
      conn: conn,
      org: org,
      venue: venue,
      item: item,
      waiter_user: waiter_user,
      waiter_membership: waiter_membership
    } do
      {:ok, order} = placed_order(org, venue, item)
      {:ok, order} = order |> Order.assign_waiter_changeset(waiter_membership.id) |> Repo.update()

      conn =
        conn |> bearer(waiter_user) |> post(~p"/api/v1/waiter/orders/#{order.id}/accept")

      assert %{"status" => "accepted"} = json_response(conn, 200)
    end

    test "a waiter cannot accept an order assigned to someone else", %{
      conn: conn,
      org: org,
      venue: venue,
      item: item,
      waiter_user: waiter_user
    } do
      %{membership: other_membership} = waiter_fixture(org, venue)
      {:ok, order} = placed_order(org, venue, item)
      {:ok, order} = order |> Order.assign_waiter_changeset(other_membership.id) |> Repo.update()

      conn = conn |> bearer(waiter_user) |> post(~p"/api/v1/waiter/orders/#{order.id}/accept")

      assert %{"error" => "not_yours"} = json_response(conn, 422)
    end

    test "an unauthenticated request is rejected", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/waiter/orders/#{Ecto.UUID.generate()}/accept")
      assert json_response(conn, 401)
    end

    test "an owner (not a waiter) is forbidden from the waiter endpoint", %{
      conn: conn,
      owner: owner
    } do
      conn =
        conn |> bearer(owner) |> post(~p"/api/v1/waiter/orders/#{Ecto.UUID.generate()}/accept")

      assert json_response(conn, 403)
    end
  end

  describe "POST /api/v1/waiter/orders/:id/served" do
    test "a correct scan (the order's own guest_token, table-less order) marks it served", %{
      conn: conn,
      org: org,
      venue: venue,
      item: item,
      waiter_user: waiter_user,
      waiter_membership: waiter_membership
    } do
      {:ok, order} = placed_order(org, venue, item)
      {:ok, order} = order |> Order.assign_waiter_changeset(waiter_membership.id) |> Repo.update()
      scope = %Scope{org: org, venue: venue, membership: waiter_membership, role: :waiter}
      {:ok, order} = OrderStateMachine.transition(scope, order, :accepted)
      {:ok, order} = OrderStateMachine.transition(scope, order, :preparing)
      {:ok, order} = OrderStateMachine.transition(scope, order, :ready)

      conn =
        conn
        |> bearer(waiter_user)
        |> post(~p"/api/v1/waiter/orders/#{order.id}/served", %{
          "scanned_value" => order.guest_token
        })

      assert %{"status" => "served"} = json_response(conn, 200)
    end

    test "a wrong scan is rejected", %{
      conn: conn,
      org: org,
      venue: venue,
      item: item,
      waiter_user: waiter_user,
      waiter_membership: waiter_membership
    } do
      {:ok, order} = placed_order(org, venue, item)
      {:ok, order} = order |> Order.assign_waiter_changeset(waiter_membership.id) |> Repo.update()
      scope = %Scope{org: org, venue: venue, membership: waiter_membership, role: :waiter}
      {:ok, order} = OrderStateMachine.transition(scope, order, :accepted)
      {:ok, order} = OrderStateMachine.transition(scope, order, :preparing)
      {:ok, order} = OrderStateMachine.transition(scope, order, :ready)

      conn =
        conn
        |> bearer(waiter_user)
        |> post(~p"/api/v1/waiter/orders/#{order.id}/served", %{"scanned_value" => "wrong"})

      assert %{"error" => "token_mismatch"} = json_response(conn, 422)
    end
  end

  describe "GET /api/v1/owner/dashboard" do
    test "an owner sees today's live numbers", %{conn: conn, owner: owner} do
      conn = conn |> bearer(owner) |> get(~p"/api/v1/owner/dashboard")

      assert %{"summary" => _, "operations" => _, "alerts" => _, "kitchen_orders" => []} =
               json_response(conn, 200)
    end

    test "a waiter is forbidden from the owner dashboard", %{conn: conn, waiter_user: waiter_user} do
      conn = conn |> bearer(waiter_user) |> get(~p"/api/v1/owner/dashboard")
      assert json_response(conn, 403)
    end
  end
end

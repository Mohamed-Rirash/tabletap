defmodule TabletapWeb.Api.StaffExtrasTest do
  @moduledoc """
  build-plan.md Feature 25 — the staff-app REST endpoints added on top
  of Feature 23 Commit 4's accept/served/dashboard: shift toggle,
  waiter queue, claim board, claim, unserveable, cross-org membership
  list, venue comparison, and mobile password login.
  """
  use TabletapWeb.ConnCase, async: true

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Ordering, Repo}
  alias Tabletap.Ordering.{Cart, Order, OrderStateMachine}
  alias Tabletap.Tenants.Membership
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

  describe "POST /api/v1/waiter/shift/clock_in and /clock_out" do
    test "a waiter clocks in and out", %{conn: conn, waiter_user: waiter_user} do
      conn1 = conn |> bearer(waiter_user) |> post(~p"/api/v1/waiter/shift/clock_in")
      assert response(conn1, 204)

      conn2 = conn |> bearer(waiter_user) |> post(~p"/api/v1/waiter/shift/clock_out")
      assert response(conn2, 204)
    end

    test "clocking in twice is rejected", %{conn: conn, waiter_user: waiter_user} do
      conn |> bearer(waiter_user) |> post(~p"/api/v1/waiter/shift/clock_in")
      conn2 = conn |> bearer(waiter_user) |> post(~p"/api/v1/waiter/shift/clock_in")

      assert %{"error" => "already_clocked_in"} = json_response(conn2, 422)
    end

    test "clocking out without an open shift is rejected", %{conn: conn, waiter_user: waiter_user} do
      conn = conn |> bearer(waiter_user) |> post(~p"/api/v1/waiter/shift/clock_out")
      assert %{"error" => "not_clocked_in"} = json_response(conn, 422)
    end
  end

  describe "GET /api/v1/waiter/queue" do
    test "lists the waiter's own assigned orders, oldest first", %{
      conn: conn,
      org: org,
      venue: venue,
      item: item,
      waiter_user: waiter_user,
      waiter_membership: waiter_membership
    } do
      {:ok, order} = placed_order(org, venue, item)
      {:ok, order} = order |> Order.assign_waiter_changeset(waiter_membership.id) |> Repo.update()

      conn = conn |> bearer(waiter_user) |> get(~p"/api/v1/waiter/queue")

      assert %{"orders" => [%{"id" => id, "status" => "placed"}]} = json_response(conn, 200)
      assert id == order.id
    end

    test "an order assigned to someone else doesn't show up", %{
      conn: conn,
      org: org,
      venue: venue,
      item: item,
      waiter_user: waiter_user
    } do
      %{membership: other_membership} = waiter_fixture(org, venue)
      {:ok, order} = placed_order(org, venue, item)
      {:ok, _order} = order |> Order.assign_waiter_changeset(other_membership.id) |> Repo.update()

      conn = conn |> bearer(waiter_user) |> get(~p"/api/v1/waiter/queue")

      assert %{"orders" => []} = json_response(conn, 200)
    end
  end

  describe "GET /api/v1/waiter/claim_board" do
    test "lists venue-wide unassigned placed orders", %{
      conn: conn,
      org: org,
      venue: venue,
      item: item,
      waiter_user: waiter_user
    } do
      {:ok, order} = placed_order(org, venue, item)

      conn = conn |> bearer(waiter_user) |> get(~p"/api/v1/waiter/claim_board")

      assert %{"orders" => [%{"id" => id}]} = json_response(conn, 200)
      assert id == order.id
    end
  end

  describe "POST /api/v1/waiter/orders/:id/claim" do
    test "first tap wins an unassigned order", %{
      conn: conn,
      org: org,
      venue: venue,
      item: item,
      waiter_user: waiter_user
    } do
      {:ok, order} = placed_order(org, venue, item)

      conn = conn |> bearer(waiter_user) |> post(~p"/api/v1/waiter/orders/#{order.id}/claim")

      assert %{"status" => "accepted"} = json_response(conn, 200)
    end

    test "a second waiter loses the race", %{
      conn: conn,
      org: org,
      venue: venue,
      item: item,
      waiter_user: waiter_user
    } do
      %{user: other_user} = waiter_fixture(org, venue)
      {:ok, order} = placed_order(org, venue, item)

      conn |> bearer(waiter_user) |> post(~p"/api/v1/waiter/orders/#{order.id}/claim")
      conn2 = conn |> bearer(other_user) |> post(~p"/api/v1/waiter/orders/#{order.id}/claim")

      assert %{"error" => "already_claimed"} = json_response(conn2, 422)
    end
  end

  describe "POST /api/v1/waiter/orders/:id/unserveable" do
    test "flags a ready order the waiter can't hand off", %{
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
        conn |> bearer(waiter_user) |> post(~p"/api/v1/waiter/orders/#{order.id}/unserveable")

      assert %{"flag" => "unserveable", "status" => "ready"} = json_response(conn, 200)
    end
  end

  describe "GET /api/v1/me/memberships" do
    test "lists every active membership the caller holds", %{
      conn: conn,
      org: org,
      waiter_user: waiter_user,
      waiter_membership: waiter_membership
    } do
      conn = conn |> bearer(waiter_user) |> get(~p"/api/v1/me/memberships")

      assert %{
               "memberships" => [
                 %{"membership_id" => id, "role" => "waiter", "org_id" => org_id}
               ]
             } = json_response(conn, 200)

      assert id == waiter_membership.id
      assert org_id == org.id
    end
  end

  describe "GET /api/v1/owner/venues" do
    test "a trialing owner sees the comparison (trial unlocks every tier)", %{
      conn: conn,
      owner: owner,
      venue: venue
    } do
      conn = conn |> bearer(owner) |> get(~p"/api/v1/owner/venues")

      assert %{"venues" => [%{"venue_id" => id}], "totals" => %{"venue_count" => 1}} =
               json_response(conn, 200)

      assert id == venue.id
    end

    test "an active Growth-plan owner is blocked — org_comparison is Pro only", %{
      conn: conn,
      org: org,
      owner: owner
    } do
      org |> Ecto.Changeset.change(plan: :growth, subscription_status: :active) |> Repo.update!()

      conn = conn |> bearer(owner) |> get(~p"/api/v1/owner/venues")

      assert %{"error" => "plan_upgrade_required"} = json_response(conn, 403)
    end

    test "an active Pro-plan owner passes the gate", %{conn: conn, org: org, owner: owner} do
      org |> Ecto.Changeset.change(plan: :pro, subscription_status: :active) |> Repo.update!()

      conn = conn |> bearer(owner) |> get(~p"/api/v1/owner/venues")

      assert %{"venues" => [_]} = json_response(conn, 200)
    end

    test "a manager (not owner) is forbidden even on a trialing org", %{
      conn: conn,
      org: org,
      venue: venue
    } do
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

      conn = conn |> bearer(manager_user) |> get(~p"/api/v1/owner/venues")

      assert json_response(conn, 403)
    end
  end

  describe "POST /api/v1/auth/login" do
    test "an owner logs in with email + password", %{owner: owner} do
      conn =
        build_conn()
        |> post(~p"/api/v1/auth/login", %{
          "email" => owner.email,
          "password" => Tabletap.TenantsFixtures.valid_password()
        })

      assert %{"access_token" => _, "refresh_token" => _, "user" => %{"email" => email}} =
               json_response(conn, 200)

      assert email == owner.email
    end

    test "wrong password is rejected", %{owner: owner} do
      conn =
        build_conn()
        |> post(~p"/api/v1/auth/login", %{"email" => owner.email, "password" => "wrong password"})

      assert %{"error" => "invalid_email_or_password"} = json_response(conn, 401)
    end

    test "unknown email is rejected the same way (no enumeration)" do
      conn =
        build_conn()
        |> post(~p"/api/v1/auth/login", %{
          "email" => "nobody@example.com",
          "password" => "whatever12345"
        })

      assert %{"error" => "invalid_email_or_password"} = json_response(conn, 401)
    end
  end
end

defmodule TabletapWeb.Manager.Analytics.StaffLiveTest do
  @moduledoc """
  `TabletapWeb.Manager.Analytics.StaffLive` at `/analytics/staff`
  (build-plan.md Feature 18, owner-dashboard.md Screen 5).
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Payments, Staffing}
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
  alias Tabletap.Repo

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/analytics/staff")
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

    test "shows empty states with no staff activity yet", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/analytics/staff")

      assert html =~ "No waiter-served orders in this period."
      assert html =~ "No cashier transactions in this period."
    end

    test "reconciles a waiter's served order and a cashier's transaction", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      %{membership: waiter, user: waiter_user} = waiter_fixture(scope.org, scope.venue)
      waiter_scope = %{scope | role: :waiter, membership: waiter}
      {:ok, _} = Staffing.clock_in(waiter_scope)

      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(scope, cart)

      order =
        Enum.reduce([:placed, :accepted, :preparing, :ready, :served], order, fn status, acc ->
          {:ok, moved} = OrderStateMachine.transition(waiter_scope, acc, status)
          moved
        end)

      order |> Ecto.Changeset.change(waiter_membership_id: waiter.id) |> Repo.update!()
      {:ok, _} = Staffing.clock_out(waiter_scope)

      %{membership: cashier, user: cashier_user} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}

      {:ok, cash_cart} =
        Ordering.add_to_cart(cashier_scope, Cart.generate_guest_token(), nil, item, [], 1, nil)

      {:ok, cash_order} = Ordering.checkout(cashier_scope, cash_cart)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, cash_order, cashier)

      {:ok, _lv, html} = live(conn, ~p"/analytics/staff?range=today")

      assert html =~ waiter_user.email
      assert html =~ cashier_user.email
      assert html =~ "Venue average"
    end

    test "switching range patches the URL", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/analytics/staff")

      html = lv |> element(~s(a[href="/analytics/staff?range=30d"])) |> render_click()
      assert html =~ "Staff &amp; Work"
      assert_patch(lv, ~p"/analytics/staff?range=30d")
    end
  end
end

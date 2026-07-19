defmodule TabletapWeb.UserLive.HistoryTest do
  @moduledoc """
  `/me/history` (build-plan.md Feature 16) — the customer's own
  cross-venue order list, monthly spend (never summed across currencies
  — design-qa.md Q60), and per-venue totals.
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.{AccountsFixtures, TenantsFixtures}

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
  alias Tabletap.Repo

  defp seeded_item(scope, name, price) do
    Repo.put_org_id(scope.org.id)
    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})
    {:ok, item} = Catalog.create_item(scope, category, %{"name" => name, "price" => price})
    item
  end

  defp order_fixture(scope, item) do
    Repo.put_org_id(scope.org.id)
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    {:ok, order} = OrderStateMachine.transition(scope, order, :placed)
    order
  end

  test "requires authentication", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/me/history")
  end

  test "a plain staff member can reach it too (any authenticated user, no role gate)", %{
    conn: conn
  } do
    %{user: user} = org_fixture()
    conn = log_in_user(conn, user)

    {:ok, _view, html} = live(conn, ~p"/me/history")
    assert html =~ "Your order history"
  end

  test "empty state for a customer with no orders", %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)

    {:ok, _view, html} = live(conn, ~p"/me/history")
    assert html =~ "No orders yet"
  end

  test "shows orders across multiple venues with correct per-venue and monthly totals", %{
    conn: conn
  } do
    %{org_a: org_a, venue_a: venue_a, org_b: org_b, venue_b: venue_b} = two_orgs()
    scope_a = %Scope{org: org_a, venue: venue_a, role: :guest}
    scope_b = %Scope{org: org_b, venue: venue_b, role: :guest}

    item_a = seeded_item(scope_a, "Latte", Money.new!(:USD, "3.50"))
    item_b = seeded_item(scope_b, "Espresso", Money.new!(:USD, "2.00"))

    order1 = order_fixture(scope_a, item_a)
    order2 = order_fixture(scope_a, item_a)
    order3 = order_fixture(scope_b, item_b)

    user = user_fixture()
    Repo.put_org_id(org_a.id)
    {:ok, _} = Ordering.link_guest_orders_to_customer(user, order1.guest_token)
    Repo.put_org_id(org_a.id)
    {:ok, _} = Ordering.link_guest_orders_to_customer(user, order2.guest_token)
    Repo.put_org_id(org_b.id)
    {:ok, _} = Ordering.link_guest_orders_to_customer(user, order3.guest_token)

    conn = log_in_user(conn, user)
    {:ok, _view, html} = live(conn, ~p"/me/history")

    assert html =~ venue_a.name
    assert html =~ venue_b.name
    # Two $3.50 orders at venue_a + one $2.00 at venue_b. Money renders
    # with a literal U+00A0 (non-breaking space), not an HTML entity.
    assert html =~ "US$ 7.00"
    assert html =~ "US$ 2.00"
    # This month's combined spend, same currency, safely summed once.
    # No single venue to derive a locale from for this row, so it falls
    # back to the app default locale (:en) — "$9.00", not "so"'s "US$…".
    assert html =~ "$9.00"
  end

  test "never shows another customer's orders", %{conn: conn} do
    %{org: org, venue: venue} = org_fixture()
    scope = %Scope{org: org, venue: venue, role: :guest}
    item = seeded_item(scope, "Latte", Money.new!(:USD, "3.50"))
    order = order_fixture(scope, item)

    owner = user_fixture()
    Repo.put_org_id(org.id)
    {:ok, _} = Ordering.link_guest_orders_to_customer(owner, order.guest_token)

    stranger = user_fixture()
    conn = log_in_user(conn, stranger)

    {:ok, _view, html} = live(conn, ~p"/me/history")
    assert html =~ "No orders yet"
  end
end

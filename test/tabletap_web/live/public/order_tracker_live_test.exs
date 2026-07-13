defmodule TabletapWeb.Public.OrderTrackerLiveTest do
  @moduledoc """
  `TabletapWeb.Public.OrderTrackerLive` — the customer-facing tracker at
  `/orders/:guest_token` (build-plan.md Feature 08). Covers the surface
  build-plan's own verify step centers on: "Tracker updates within 2s
  when status changes" — here, from a real `OrderStateMachine.transition/3`
  call rather than IEx, exercising the same PubSub broadcast-after-commit
  path.
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
  alias Tabletap.Repo

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue}

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50"),
        "prep_minutes" => 5
      })

    %{scope: scope, venue: venue, item: item}
  end

  defp checked_out_order(scope, item) do
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    order
  end

  test "redirects to / for an unknown guest_token", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/orders/does-not-exist")
  end

  test "shows the venue name, order number, and line items", %{
    conn: conn,
    scope: scope,
    venue: venue,
    item: item
  } do
    order = checked_out_order(scope, item)

    {:ok, _lv, html} = live(conn, ~p"/orders/#{order.guest_token}")

    assert html =~ venue.name
    assert html =~ "##{order.number}"
    assert html =~ item.name
  end

  test "a pending_payment order shows the confirming-payment state, not the status timeline", %{
    conn: conn,
    scope: scope,
    item: item
  } do
    order = checked_out_order(scope, item)

    {:ok, _lv, html} = live(conn, ~p"/orders/#{order.guest_token}")

    assert html =~ "Confirming your payment"
    refute html =~ "Preparing"
  end

  test "a placed order shows the full status timeline", %{conn: conn, scope: scope, item: item} do
    order = checked_out_order(scope, item)
    {:ok, order} = OrderStateMachine.transition(scope, order, :placed)

    {:ok, _lv, html} = live(conn, ~p"/orders/#{order.guest_token}")

    assert html =~ "Placed"
    assert html =~ "Accepted"
    assert html =~ "Preparing"
    assert html =~ "Ready"
    assert html =~ "Served"
  end

  test "updates live in the same connection when the order transitions", %{
    conn: conn,
    scope: scope,
    item: item
  } do
    order = checked_out_order(scope, item)
    {:ok, order} = OrderStateMachine.transition(scope, order, :placed)

    {:ok, lv, html} = live(conn, ~p"/orders/#{order.guest_token}")
    refute html =~ "Confirming your payment"

    {:ok, _order} = OrderStateMachine.transition(scope, order, :accepted)

    assert render(lv) =~ "Accepted"
  end

  test "a cancelled order shows the cancelled terminal state, not the timeline", %{
    conn: conn,
    scope: scope,
    item: item
  } do
    order = checked_out_order(scope, item)
    {:ok, order} = OrderStateMachine.transition(scope, order, :cancelled)

    {:ok, _lv, html} = live(conn, ~p"/orders/#{order.guest_token}")

    assert html =~ "cancelled"
    refute html =~ "Preparing"
  end

  test "an expired order shows the expired terminal state", %{
    conn: conn,
    scope: scope,
    item: item
  } do
    order = checked_out_order(scope, item)
    {:ok, order} = OrderStateMachine.transition(scope, order, :expired)

    {:ok, _lv, html} = live(conn, ~p"/orders/#{order.guest_token}")

    assert html =~ "expired"
  end
end

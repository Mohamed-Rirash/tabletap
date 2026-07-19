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

  import Mox
  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Feedback
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
  alias Tabletap.Payments
  alias Tabletap.Payments.ProviderMock
  alias Tabletap.Repo

  setup :verify_on_exit!

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

  @forward_path [:placed, :accepted, :preparing, :ready, :served]

  defp served_order(scope, item) do
    order = checked_out_order(scope, item)

    order =
      Enum.reduce(@forward_path, order, fn status, acc ->
        {:ok, moved} = OrderStateMachine.transition(scope, acc, status)
        moved
      end)

    Repo.preload(order, :items)
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

  test "an expired order that was charged then auto-refunded (Q21) shows the sold-out-refunded message, not the plain expiry one",
       %{conn: conn, scope: scope, venue: venue, item: item} do
    venue = charges_enabled_venue_fixture(venue)
    scope = %{scope | venue: venue}

    {:ok, _} = Catalog.set_daily_limit(scope, item, 1)
    order = checked_out_order(scope, item)
    {:ok, payment} = Payments.charge_order(scope, order, "252611111111")
    {:ok, _} = OrderStateMachine.transition(scope, order, :expired)

    # A different guest takes the last portion in the interim, so the
    # late-arriving APPROVED confirmation can't be fulfilled.
    _other_order = checked_out_order(scope, item)

    expect(ProviderMock, :refund, fn _creds, _txn, _amount ->
      {:ok, %{provider_refund_id: "r1"}}
    end)

    assert {:ok, :refunded} = Payments.confirm_approved(payment.id, "late-txn")

    {:ok, _lv, html} = live(conn, ~p"/orders/#{order.guest_token}")

    assert html =~ "sold out while your payment was confirming"
    refute html =~ "expired before payment was confirmed"
  end

  describe "save your history (build-plan.md Feature 16)" do
    test "hidden while the order is still pending_payment", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      order = checked_out_order(scope, item)
      {:ok, _lv, html} = live(conn, ~p"/orders/#{order.guest_token}")

      refute html =~ "Save your order history"
    end

    test "shown once the order has placed, and hidden again once linked", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      order = checked_out_order(scope, item)
      {:ok, order} = OrderStateMachine.transition(scope, order, :placed)

      {:ok, _lv, html} = live(conn, ~p"/orders/#{order.guest_token}")
      assert html =~ "Save your order history"

      user = Tabletap.AccountsFixtures.user_fixture()
      {:ok, _} = Ordering.link_guest_orders_to_customer(user, order.guest_token)

      {:ok, _lv, html} = live(conn, ~p"/orders/#{order.guest_token}")
      refute html =~ "Save your order history"
    end

    test "submitting a new email finds-or-registers the account and confirms the generic message",
         %{conn: conn, scope: scope, item: item} do
      order = checked_out_order(scope, item)
      {:ok, order} = OrderStateMachine.transition(scope, order, :placed)

      {:ok, lv, _html} = live(conn, ~p"/orders/#{order.guest_token}")

      email = "customer-#{System.unique_integer([:positive])}@example.com"

      html =
        lv
        |> form("#signup-form", signup: %{"email" => email})
        |> render_submit()

      assert html =~ "a magic link is on its way"

      # find-or-register happened — the account exists, unconfirmed, ready
      # for whatever magic link was just sent to claim it. The actual
      # confirm-triggers-linking round trip is covered end to end by
      # confirmation_test.exs's own "guest order linking" tests.
      user = Tabletap.Accounts.get_user_by_email(email)
      assert user
      refute user.confirmed_at
    end
  end

  describe "rate an order item (build-plan.md Feature 17)" do
    test "hidden while the order hasn't been served yet", %{conn: conn, scope: scope, item: item} do
      order = checked_out_order(scope, item)
      {:ok, order} = OrderStateMachine.transition(scope, order, :placed)

      {:ok, _lv, html} = live(conn, ~p"/orders/#{order.guest_token}")

      refute html =~ "select_stars"
    end

    test "shown once served, comment box gated behind a star pick, and submitting rates it", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      order = served_order(scope, item)
      [order_item] = order.items

      {:ok, lv, html} = live(conn, ~p"/orders/#{order.guest_token}")
      assert html =~ "select_stars"
      refute html =~ "Optional comment"

      html =
        lv
        |> element(~s(button[phx-value-item_id="#{order_item.id}"][phx-value-stars="4"]))
        |> render_click()

      assert html =~ "Optional comment"

      html =
        lv
        |> form("form[phx-submit=\"submit_rating\"]", %{
          "item_id" => order_item.id,
          "comment" => "Great!"
        })
        |> render_submit()

      assert html =~ "Thanks for rating this!"
      refute html =~ "Optional comment"

      [rating] = Feedback.list_venue_feedback(scope)
      assert rating.stars == 4
      assert rating.comment == "Great!"
      assert rating.order_item_id == order_item.id
    end

    test "re-rendering after a rating hides the widget on reload", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      order = served_order(scope, item)
      [order_item] = order.items
      {:ok, _} = Feedback.rate_item(scope, order, order_item, 5)

      {:ok, _lv, html} = live(conn, ~p"/orders/#{order.guest_token}")

      assert html =~ "Thanks for rating this!"
      refute html =~ "select_stars"
    end

    test "the widget appears live when the order transitions to served in the same connection", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      order = checked_out_order(scope, item)
      {:ok, order} = OrderStateMachine.transition(scope, order, :placed)
      order = Repo.preload(order, :items)

      {:ok, lv, html} = live(conn, ~p"/orders/#{order.guest_token}")
      refute html =~ "select_stars"

      order =
        Enum.reduce([:accepted, :preparing, :ready, :served], order, fn status, acc ->
          {:ok, moved} = OrderStateMachine.transition(scope, acc, status)
          moved
        end)

      assert render(lv) =~ "select_stars"
      _ = order
    end
  end
end

defmodule TabletapWeb.Waiter.QueueLiveTest do
  @moduledoc """
  `Waiter.QueueLive` — currently just the Web Push opt-in wiring
  (build-plan.md Feature 20). This LiveView has no other test
  coverage yet; that's a pre-existing gap, not something this feature
  takes on backfilling.
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Notifications
  alias Tabletap.Notifications.PushSubscription
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, Order, OrderStateMachine}
  alias Tabletap.Repo

  setup %{conn: conn} do
    %{org: org, venue: venue} = org_fixture()
    %{user: user} = waiter_fixture(org, venue)

    %{conn: log_in_user(conn, user), user: user}
  end

  test "shows the enable-notifications button with the VAPID public key", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/waiter")

    assert html =~ "Enable notifications"
    assert html =~ Notifications.vapid_public_key()
  end

  test "push_subscribe persists a subscription for the current user", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/waiter")

    render_hook(lv, "push_subscribe", %{
      "endpoint" => "https://push.example.com/waiter-1",
      "p256dh" =>
        "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM",
      "auth" => "tBHItJI5svbpez7KI4CCXg",
      "user_agent" => "Test/1.0"
    })

    assert [%PushSubscription{} = subscription] = Repo.all(PushSubscription, skip_org_id: true)
    assert subscription.user_id == user.id
    assert subscription.endpoint == "https://push.example.com/waiter-1"
  end

  test "links the waiter PWA manifest and renders the install-prompt button (build-plan.md Feature 20)",
       %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/waiter")

    assert html =~ ~s(rel="manifest" href="/manifest-waiter.webmanifest")
    assert html =~ ~s(id="pwa-install-button")
  end

  test "renders the iOS install-to-home-screen gate, hidden by default (design-qa.md Q28)", %{
    conn: conn
  } do
    {:ok, _lv, html} = live(conn, ~p"/waiter")

    assert html =~ ~s(id="ios-install-gate")
    assert html =~ "Add TableTap to your Home Screen"
    # Client-only knowledge (`navigator.standalone`) decides visibility —
    # the server always renders it hidden; IosInstallGate's `mounted()`
    # is what reveals it, only on a non-installed iOS Safari.
    assert html =~ ~s(class="hidden fixed inset-0 z-50")
  end

  describe "cross-tenant isolation (build-plan.md Feature 22)" do
    defp other_org_placed_order do
      %{org: org, venue: venue} = org_fixture()
      Repo.put_org_id(org.id)
      scope = %Scope{org: org, venue: venue, role: :owner}

      {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

      {:ok, item} =
        Catalog.create_item(scope, category, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "3.50")
        })

      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(scope, cart)
      {:ok, order} = OrderStateMachine.transition(scope, order, :placed)
      order
    end

    test "accept_order on another org's order id is a safe no-op, never a leak", %{conn: conn} do
      other_order = other_org_placed_order()
      {:ok, lv, _html} = live(conn, ~p"/waiter")

      render_click(lv, "accept_order", %{"id" => other_order.id})

      assert Repo.get(Order, other_order.id, skip_org_id: true).status == :placed
      assert is_nil(Repo.get(Order, other_order.id, skip_org_id: true).waiter_membership_id)
    end

    test "claim_order on another org's order id never claims it", %{conn: conn} do
      other_order = other_org_placed_order()
      {:ok, lv, _html} = live(conn, ~p"/waiter")

      render_click(lv, "claim_order", %{"id" => other_order.id})

      assert is_nil(Repo.get(Order, other_order.id, skip_org_id: true).waiter_membership_id)
    end

    test "mark_unserveable on another org's order id is a safe no-op", %{conn: conn} do
      other_order = other_org_placed_order()
      {:ok, lv, _html} = live(conn, ~p"/waiter")

      render_click(lv, "mark_unserveable", %{"id" => other_order.id})

      refute Repo.get(Order, other_order.id, skip_org_id: true).flag
    end
  end
end

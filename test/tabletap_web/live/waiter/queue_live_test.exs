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

  alias Tabletap.Notifications
  alias Tabletap.Notifications.PushSubscription
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
end

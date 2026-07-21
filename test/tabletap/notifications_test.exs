defmodule Tabletap.NotificationsTest do
  @moduledoc """
  `Tabletap.Notifications` — subscribe/unsubscribe (idempotent on the
  same device), and `send_push/2`'s stale-subscription cleanup on a
  404/410 response. The actual HTTP call is stubbed via `Req.Test`
  (config/test.exs routes `Notifications`' own Req options through it)
  — no test ever reaches a real push service (code-standards.md).
  """
  use Tabletap.DataCase, async: true

  import Tabletap.AccountsFixtures

  alias Tabletap.Notifications
  alias Tabletap.Notifications.PushSubscription
  alias Tabletap.Repo

  defp subscription_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "endpoint" => "https://push.example.com/#{System.unique_integer()}",
        "p256dh" =>
          "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM",
        "auth" => "tBHItJI5svbpez7KI4CCXg",
        "user_agent" => "Test/1.0"
      },
      overrides
    )
  end

  describe "subscribe/2 and unsubscribe/2" do
    test "creates a subscription for the user" do
      user = user_fixture()

      assert {:ok, %PushSubscription{} = subscription} =
               Notifications.subscribe(user, subscription_attrs())

      assert subscription.user_id == user.id
      assert [^subscription] = Notifications.list_subscriptions_for_user(user.id)
    end

    test "re-subscribing the same device (endpoint) updates, not duplicates" do
      user = user_fixture()
      attrs = subscription_attrs()

      assert {:ok, first} = Notifications.subscribe(user, attrs)

      assert {:ok, second} =
               Notifications.subscribe(user, Map.put(attrs, "auth", "a-new-auth-secret"))

      assert first.id == second.id
      assert [reloaded] = Notifications.list_subscriptions_for_user(user.id)
      assert reloaded.auth == "a-new-auth-secret"
    end

    test "unsubscribe removes only the matching endpoint" do
      user = user_fixture()

      {:ok, _kept} =
        Notifications.subscribe(
          user,
          subscription_attrs(%{"endpoint" => "https://push.example.com/kept"})
        )

      {:ok, _removed} =
        Notifications.subscribe(
          user,
          subscription_attrs(%{"endpoint" => "https://push.example.com/removed"})
        )

      assert :ok = Notifications.unsubscribe(user, "https://push.example.com/removed")

      assert [remaining] = Notifications.list_subscriptions_for_user(user.id)
      assert remaining.endpoint == "https://push.example.com/kept"
    end
  end

  describe "send_push/2" do
    test "a successful push leaves the subscription in place" do
      user = user_fixture()
      {:ok, subscription} = Notifications.subscribe(user, subscription_attrs())

      Req.Test.stub(Tabletap.Notifications, fn conn ->
        Plug.Conn.send_resp(conn, 201, "")
      end)

      assert :ok = Notifications.send_push(subscription, %{title: "New order", body: "Table 4"})
      assert Repo.get(PushSubscription, subscription.id, skip_org_id: true)
    end

    test "a 410 Gone response deletes the dead subscription" do
      user = user_fixture()
      {:ok, subscription} = Notifications.subscribe(user, subscription_attrs())

      Req.Test.stub(Tabletap.Notifications, fn conn ->
        Plug.Conn.send_resp(conn, 410, "")
      end)

      assert :ok = Notifications.send_push(subscription, %{title: "New order", body: "Table 4"})
      refute Repo.get(PushSubscription, subscription.id, skip_org_id: true)
    end

    test "a 404 Not Found response also deletes the dead subscription" do
      user = user_fixture()
      {:ok, subscription} = Notifications.subscribe(user, subscription_attrs())

      Req.Test.stub(Tabletap.Notifications, fn conn ->
        Plug.Conn.send_resp(conn, 404, "")
      end)

      assert :ok = Notifications.send_push(subscription, %{title: "New order", body: "Table 4"})
      refute Repo.get(PushSubscription, subscription.id, skip_org_id: true)
    end

    test "notify_user/2 sends to every subscription the user has" do
      user = user_fixture()

      {:ok, _a} =
        Notifications.subscribe(
          user,
          subscription_attrs(%{"endpoint" => "https://push.example.com/a"})
        )

      {:ok, _b} =
        Notifications.subscribe(
          user,
          subscription_attrs(%{"endpoint" => "https://push.example.com/b"})
        )

      test_pid = self()

      Req.Test.stub(Tabletap.Notifications, fn conn ->
        send(test_pid, {:pushed, conn.host})
        Plug.Conn.send_resp(conn, 201, "")
      end)

      assert :ok = Notifications.notify_user(user.id, %{title: "Low stock", body: "Milk"})
      assert_received {:pushed, _}
      assert_received {:pushed, _}
    end
  end
end

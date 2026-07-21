defmodule Tabletap.Notifications.Workers.SendPushTest do
  @moduledoc """
  `"low_stock"` and `"stuck_order"` (build-plan.md Feature 21) share one
  `perform/1` clause — both deliver to every manager/owner for the
  venue. The HTTP call is stubbed via `Req.Test`, same seam
  `notifications_test.exs` already uses.
  """
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Tabletap.TenantsFixtures

  alias Tabletap.Notifications
  alias Tabletap.Notifications.Workers.SendPush
  alias Tabletap.Repo

  defp subscribe!(user) do
    {:ok, _} =
      Notifications.subscribe(user, %{
        "endpoint" => "https://push.example.com/#{System.unique_integer()}",
        "p256dh" =>
          "BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM",
        "auth" => "tBHItJI5svbpez7KI4CCXg",
        "user_agent" => "Test/1.0"
      })
  end

  test "\"stuck_order\" pushes to the venue's owner (same audience as low_stock)" do
    %{org: org, venue: venue, user: owner_user} = org_fixture()
    Repo.put_org_id(org.id)
    {:ok, subscription} = subscribe!(owner_user)

    Req.Test.stub(Tabletap.Notifications, fn conn ->
      Plug.Conn.send_resp(conn, 201, "")
    end)

    assert :ok =
             perform_job(SendPush, %{
               "type" => "stuck_order",
               "org_id" => org.id,
               "venue_id" => venue.id,
               "title" => "Order running late",
               "body" => "Order #1 is past its expected time",
               "url" => "/orders"
             })

    # A real push attempt happened and succeeded — a dead-subscription
    # response (404/410) would have deleted this row instead.
    assert Repo.get(Tabletap.Notifications.PushSubscription, subscription.id, skip_org_id: true)
  end
end

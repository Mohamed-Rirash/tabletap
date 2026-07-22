defmodule TabletapWeb.VenueChannelTest do
  @moduledoc """
  build-plan.md Feature 23 Commit 3 — `venue:{id}:claim_board` (waiter
  role only, mirrors `Waiter.QueueLive`'s `:require_waiter` gate) and
  `venue:{id}:orders` (manager/owner, mirrors `Manager.DashboardLive`'s
  `:require_manager` gate).
  """
  use TabletapWeb.ChannelCase, async: true

  import Tabletap.TenantsFixtures

  alias TabletapWeb.{ApiAuth, ApiSocket}

  setup do
    %{org: org, venue: venue, user: owner} = org_fixture()
    %{user: waiter_user} = waiter_fixture(org, venue)

    %{venue: venue, owner: owner, waiter_user: waiter_user}
  end

  defp socket_for(user) do
    {:ok, socket} = connect(ApiSocket, %{"token" => ApiAuth.sign_access_token(user)})
    socket
  end

  test "a waiter joins the claim board and receives venue_updated broadcasts", %{
    venue: venue,
    waiter_user: waiter_user
  } do
    {:ok, _reply, _socket} =
      subscribe_and_join(socket_for(waiter_user), "venue:#{venue.id}:claim_board", %{})

    Phoenix.PubSub.broadcast(
      Tabletap.PubSub,
      "venue:#{venue.id}:claim_board",
      {:order_needs_claim, Ecto.UUID.generate()}
    )

    assert_push "venue_updated", %{event: :order_needs_claim}
  end

  test "an owner cannot join the claim board (waiter-only, mirrors the web gate)", %{
    venue: venue,
    owner: owner
  } do
    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket_for(owner), "venue:#{venue.id}:claim_board", %{})
  end

  test "an owner joins the orders topic and receives venue_updated broadcasts", %{
    venue: venue,
    owner: owner
  } do
    {:ok, _reply, _socket} =
      subscribe_and_join(socket_for(owner), "venue:#{venue.id}:orders", %{})

    Phoenix.PubSub.broadcast(
      Tabletap.PubSub,
      "venue:#{venue.id}:orders",
      {:order_updated, Ecto.UUID.generate()}
    )

    assert_push "venue_updated", %{event: :order_updated}
  end

  test "a waiter cannot join the orders topic (manager/owner-only)", %{
    venue: venue,
    waiter_user: waiter_user
  } do
    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket_for(waiter_user), "venue:#{venue.id}:orders", %{})
  end

  test "a staff member of a different venue cannot join this venue's channels", %{venue: venue} do
    %{org: other_org, venue: other_venue} = org_fixture()
    %{user: other_waiter} = waiter_fixture(other_org, other_venue)

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket_for(other_waiter), "venue:#{venue.id}:claim_board", %{})
  end

  test "an unknown topic suffix is rejected", %{venue: venue, owner: owner} do
    assert {:error, %{reason: "unknown_topic"}} =
             subscribe_and_join(socket_for(owner), "venue:#{venue.id}:something_else", %{})
  end
end

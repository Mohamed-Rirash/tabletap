defmodule TabletapWeb.WaiterChannelTest do
  @moduledoc """
  build-plan.md Feature 23 Commit 3 — `waiter:{membership_id}` requires
  the bearer-authenticated caller to actually hold that membership.
  """
  use TabletapWeb.ChannelCase, async: true

  import Tabletap.TenantsFixtures

  alias TabletapWeb.{ApiAuth, ApiSocket}

  setup do
    %{org: org, venue: venue} = org_fixture()
    %{user: user, membership: membership} = waiter_fixture(org, venue)
    token = ApiAuth.sign_access_token(user)

    {:ok, socket} = connect(ApiSocket, %{"token" => token})

    %{socket: socket, membership: membership, user: user}
  end

  test "the membership's own user joins and receives queue_updated broadcasts", %{
    socket: socket,
    membership: membership
  } do
    {:ok, _reply, _socket} = subscribe_and_join(socket, "waiter:#{membership.id}", %{})

    Phoenix.PubSub.broadcast(
      Tabletap.PubSub,
      "waiter:#{membership.id}",
      {:order_assigned, Ecto.UUID.generate()}
    )

    assert_push "queue_updated", %{event: :order_assigned}
  end

  test "a different user cannot join someone else's waiter channel", %{membership: membership} do
    other_user = Tabletap.AccountsFixtures.user_fixture()
    token = ApiAuth.sign_access_token(other_user)
    {:ok, socket} = connect(ApiSocket, %{"token" => token})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "waiter:#{membership.id}", %{})
  end

  test "an unauthenticated (no-token) socket cannot join" do
    {:ok, socket} = connect(ApiSocket, %{})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "waiter:#{Ecto.UUID.generate()}", %{})
  end

  test "a malformed membership id is rejected, not a crash", %{socket: socket} do
    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "waiter:not-a-uuid", %{})
  end
end

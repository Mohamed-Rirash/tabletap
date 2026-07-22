defmodule TabletapWeb.WaiterChannelTest do
  @moduledoc """
  build-plan.md Feature 23 Commit 3 (`waiter:{membership_id}` requires
  the bearer-authenticated caller to actually hold that membership) and
  Feature 25 (the channel also tracks/untracks this waiter's
  `TabletapWeb.Presence` entry, since a mobile shift toggle is a
  stateless REST call with no long-lived process of its own).
  """
  use TabletapWeb.ChannelCase, async: false

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Staffing
  alias TabletapWeb.{ApiAuth, ApiSocket, Presence}

  setup do
    %{org: org, venue: venue} = org_fixture()
    %{user: user, membership: membership} = waiter_fixture(org, venue)
    token = ApiAuth.sign_access_token(user)
    Tabletap.Repo.put_org_id(org.id)

    {:ok, socket} = connect(ApiSocket, %{"token" => token})

    %{socket: socket, membership: membership, user: user, org: org, venue: venue}
  end

  # Phoenix.Presence's own `handle_metas/4` (which is what actually
  # updates `Presence.alive?/2`'s backing ETS table) runs asynchronously
  # relative to `Presence.track/4` returning — poll briefly rather than
  # assuming a fixed delay is always enough.
  defp wait_until(fun, attempts \\ 20) do
    cond do
      fun.() -> :ok
      attempts <= 1 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
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

  describe "Presence tracking" do
    test "joining off-shift does not make the waiter an assignment candidate", %{
      socket: socket,
      membership: membership,
      venue: venue
    } do
      {:ok, _reply, _socket} = subscribe_and_join(socket, "waiter:#{membership.id}", %{})

      refute Presence.alive?(venue.id, membership.id)
    end

    test "joining already on-shift tracks Presence immediately", %{
      socket: socket,
      membership: membership,
      org: org,
      venue: venue
    } do
      {:ok, _shift} = Staffing.clock_in(%Scope{org: org, venue: venue, membership: membership})

      {:ok, _reply, _socket} = subscribe_and_join(socket, "waiter:#{membership.id}", %{})

      wait_until(fn -> Presence.alive?(venue.id, membership.id) end)
    end

    test "clocking in while already joined tracks Presence via the :shift_changed broadcast", %{
      socket: socket,
      membership: membership,
      org: org,
      venue: venue
    } do
      {:ok, _reply, _socket} = subscribe_and_join(socket, "waiter:#{membership.id}", %{})
      refute Presence.alive?(venue.id, membership.id)

      {:ok, _shift} = Staffing.clock_in(%Scope{org: org, venue: venue, membership: membership})

      wait_until(fn -> Presence.alive?(venue.id, membership.id) end)
    end

    test "clocking out while joined starts the untrack (design-qa.md Q55's ~30s flap grace means `alive?/2` doesn't drop instantly — `confirm_leave/2` below is what the real timer eventually calls)",
         %{
           socket: socket,
           membership: membership,
           org: org,
           venue: venue
         } do
      {:ok, _shift} = Staffing.clock_in(%Scope{org: org, venue: venue, membership: membership})
      {:ok, _reply, _socket} = subscribe_and_join(socket, "waiter:#{membership.id}", %{})
      wait_until(fn -> Presence.alive?(venue.id, membership.id) end)

      {:ok, _shift} = Staffing.clock_out(%Scope{membership: membership})

      # Give the channel's own untrack a moment to actually land before
      # forcing the grace timer's own eventual callback.
      wait_until(fn ->
        Presence.confirm_leave(venue.id, membership.id)
        not Presence.alive?(venue.id, membership.id)
      end)
    end
  end
end

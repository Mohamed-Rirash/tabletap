defmodule TabletapWeb.OrderChannelTest do
  @moduledoc """
  build-plan.md Feature 23 Commit 3 — `order:{id}` relays the exact
  `:order_updated` broadcast `OrderStateMachine.transition/3` already
  fires, same topic `Public.OrderTrackerLive` subscribes to.
  """
  use TabletapWeb.ChannelCase, async: true

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Ordering, Repo}
  alias Tabletap.Ordering.OrderStateMachine
  alias TabletapWeb.ApiSocket

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue, role: :guest}

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    guest_token = Ordering.Cart.generate_guest_token()
    {:ok, _cart} = Ordering.add_to_cart(scope, guest_token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, Ordering.get_active_cart(scope, guest_token))

    {:ok, socket} = connect(ApiSocket, %{})

    %{socket: socket, order: order, guest_token: guest_token, scope: scope}
  end

  test "the right guest_token joins and receives order_updated broadcasts", %{
    socket: socket,
    order: order,
    guest_token: guest_token,
    scope: scope
  } do
    {:ok, _reply, _socket} =
      subscribe_and_join(socket, "order:#{order.id}", %{"guest_token" => guest_token})

    {:ok, order} = OrderStateMachine.transition(scope, order, :placed)

    assert_push "order_updated", payload
    assert payload.status == order.status
    assert payload.id == order.id
  end

  test "a wrong guest_token is rejected", %{socket: socket, order: order} do
    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "order:#{order.id}", %{"guest_token" => "wrong-token"})
  end

  test "joining with no guest_token is rejected", %{socket: socket, order: order} do
    assert {:error, %{reason: "guest_token_required"}} =
             subscribe_and_join(socket, "order:#{order.id}", %{})
  end

  test "a different order's real guest_token doesn't unlock this one", %{
    socket: socket,
    order: order,
    scope: scope
  } do
    {_category, [item]} = scope |> Catalog.list_public_menu() |> hd()
    other_guest_token = Ordering.Cart.generate_guest_token()
    {:ok, _cart} = Ordering.add_to_cart(scope, other_guest_token, nil, item, [], 1, nil)

    {:ok, _other_order} =
      Ordering.checkout(scope, Ordering.get_active_cart(scope, other_guest_token))

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "order:#{order.id}", %{"guest_token" => other_guest_token})
  end
end

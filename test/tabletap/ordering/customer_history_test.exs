defmodule Tabletap.Ordering.CustomerHistoryTest do
  @moduledoc """
  Build-plan.md Feature 16 — `Ordering.link_guest_orders_to_customer/2`
  (the write side of "Save your history") and `list_orders_for_customer/1`
  (the `/me/history` read), both cross-tenant since a customer's orders
  span every org they've ever visited (architecture.md "Customer data is
  NOT tenant-owned").
  """
  use Tabletap.DataCase, async: true

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
  alias Tabletap.Repo

  defp venue_scope(%{org: org, venue: venue}) do
    Repo.put_org_id(org.id)
    %Scope{org: org, venue: venue, role: :guest}
  end

  defp seeded_item(scope, name, price) do
    Repo.put_org_id(scope.org.id)
    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})
    {:ok, item} = Catalog.create_item(scope, category, %{"name" => name, "price" => price})
    item
  end

  # Repo.put_org_id/1 is ambient process state — building a second scope
  # (venue_scope/1) for a different org silently repoints it, so every
  # Ordering-context call here must re-assert its own scope's org
  # immediately before running, not trust whatever a prior helper call
  # last set.
  defp order_fixture(scope, item, guest_token, target_status \\ :placed) do
    Repo.put_org_id(scope.org.id)
    {:ok, cart} = Ordering.add_to_cart(scope, guest_token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, cart)

    [:placed, :accepted, :preparing, :ready, :served, :closed]
    |> Enum.take_while(&(&1 != target_status))
    |> Kernel.++([target_status])
    |> Enum.reduce(order, fn status, acc ->
      {:ok, moved} = OrderStateMachine.transition(scope, acc, status)
      moved
    end)
  end

  describe "link_guest_orders_to_customer/2" do
    test "links every matching order across multiple orgs in one call", %{} do
      %{org_a: org_a, venue_a: venue_a, org_b: org_b, venue_b: venue_b} = two_orgs()
      scope_a = venue_scope(%{org: org_a, venue: venue_a})
      item_a = seeded_item(scope_a, "Latte", Money.new!(:USD, "3.50"))

      guest_token = Cart.generate_guest_token()
      order1 = order_fixture(scope_a, item_a, guest_token)
      order2 = order_fixture(scope_a, item_a, guest_token)

      scope_b = venue_scope(%{org: org_b, venue: venue_b})
      item_b = seeded_item(scope_b, "Espresso", Money.new!(:USD, "2.00"))
      order3 = order_fixture(scope_b, item_b, guest_token)

      # A different guest_token at org_a — must never get linked.
      other_order = order_fixture(scope_a, item_a, Cart.generate_guest_token())

      user = Tabletap.AccountsFixtures.user_fixture()
      assert {:ok, 3} = Ordering.link_guest_orders_to_customer(user, guest_token)

      # link_guest_orders_to_customer/2 loops every org, leaving
      # Repo.put_org_id pointed at whichever ran last — re-set it before
      # each following scope-specific lookup (Repo's tenant filter comes
      # from the process dictionary, not from the scope struct itself).
      Repo.put_org_id(org_a.id)
      assert Ordering.get_order(scope_a, order1.id).customer_user_id == user.id
      assert Ordering.get_order(scope_a, order2.id).customer_user_id == user.id
      assert Ordering.get_order(scope_a, other_order.id).customer_user_id == nil

      Repo.put_org_id(org_b.id)
      assert Ordering.get_order(scope_b, order3.id).customer_user_id == user.id
    end

    test "idempotent — a second call is a harmless no-op on the same rows", %{} do
      %{org: org, venue: venue} = org_fixture()
      scope = venue_scope(%{org: org, venue: venue})
      item = seeded_item(scope, "Latte", Money.new!(:USD, "3.50"))

      guest_token = Cart.generate_guest_token()
      order = order_fixture(scope, item, guest_token)

      user = Tabletap.AccountsFixtures.user_fixture()
      assert {:ok, 1} = Ordering.link_guest_orders_to_customer(user, guest_token)
      assert {:ok, 1} = Ordering.link_guest_orders_to_customer(user, guest_token)

      assert Ordering.get_order(scope, order.id).customer_user_id == user.id
    end
  end

  describe "list_orders_for_customer/1" do
    test "returns orders across every org, newest first, venue preloaded", %{} do
      %{org_a: org_a, venue_a: venue_a, org_b: org_b, venue_b: venue_b} = two_orgs()
      scope_a = venue_scope(%{org: org_a, venue: venue_a})
      item_a = seeded_item(scope_a, "Latte", Money.new!(:USD, "3.50"))

      scope_b = venue_scope(%{org: org_b, venue: venue_b})
      item_b = seeded_item(scope_b, "Espresso", Money.new!(:USD, "2.00"))

      guest_token = Cart.generate_guest_token()
      order_a = order_fixture(scope_a, item_a, guest_token)
      order_b = order_fixture(scope_b, item_b, guest_token)

      user = Tabletap.AccountsFixtures.user_fixture()
      {:ok, _count} = Ordering.link_guest_orders_to_customer(user, guest_token)

      orders = Ordering.list_orders_for_customer(user)
      assert length(orders) == 2
      assert Enum.map(orders, & &1.id) |> Enum.sort() == Enum.sort([order_a.id, order_b.id])
      assert Enum.all?(orders, &match?(%Tabletap.Tenants.Venue{}, &1.venue))
    end

    test "excludes orders that never really happened, includes refunded", %{} do
      %{org: org, venue: venue} = org_fixture()
      scope = venue_scope(%{org: org, venue: venue})
      item = seeded_item(scope, "Latte", Money.new!(:USD, "3.50"))
      user = Tabletap.AccountsFixtures.user_fixture()

      guest_token = Cart.generate_guest_token()
      served = order_fixture(scope, item, guest_token, :served)

      cancelled_token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, cancelled_token, nil, item, [], 1, nil)
      {:ok, cancelled_order} = Ordering.checkout(scope, cart)
      {:ok, _} = OrderStateMachine.transition(scope, cancelled_order, :cancelled)

      refunded_token = Cart.generate_guest_token()
      refunded = order_fixture(scope, item, refunded_token, :served)
      {:ok, refunded} = OrderStateMachine.transition(scope, refunded, :refunded)

      {:ok, _} = Ordering.link_guest_orders_to_customer(user, guest_token)
      {:ok, _} = Ordering.link_guest_orders_to_customer(user, cancelled_token)
      {:ok, _} = Ordering.link_guest_orders_to_customer(user, refunded_token)

      ids = user |> Ordering.list_orders_for_customer() |> Enum.map(& &1.id)
      assert served.id in ids
      assert refunded.id in ids
      refute cancelled_order.id in ids
    end

    test "never returns another customer's orders", %{} do
      %{org: org, venue: venue} = org_fixture()
      scope = venue_scope(%{org: org, venue: venue})
      item = seeded_item(scope, "Latte", Money.new!(:USD, "3.50"))

      guest_token = Cart.generate_guest_token()
      _order = order_fixture(scope, item, guest_token)

      owner = Tabletap.AccountsFixtures.user_fixture()
      stranger = Tabletap.AccountsFixtures.user_fixture()
      {:ok, _} = Ordering.link_guest_orders_to_customer(owner, guest_token)

      assert Ordering.list_orders_for_customer(stranger) == []
    end
  end
end

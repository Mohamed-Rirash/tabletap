defmodule Tabletap.Ordering.CheckoutTest do
  @moduledoc """
  `Ordering.checkout/2` — gates, atomic hold reservation, order-number
  assignment, and snapshotting. The concurrency test is build-plan.md
  Feature 08's own verify step, word for word: "two simultaneous
  checkouts for the last limited portion — exactly one reaches payment,
  the other sees sold-out before being charged."
  """
  use Tabletap.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Ordering, Repo, Tenants}
  alias Tabletap.Ordering.Cart

  import Tabletap.TenantsFixtures

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue}

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    %{scope: scope, org: org, venue: venue, item: item}
  end

  defp cart_fixture(scope, item, qty \\ 1) do
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], qty, nil)
    cart
  end

  describe "checkout/2 — happy path" do
    test "creates a pending_payment order with the right snapshot and number", %{
      scope: scope,
      item: item
    } do
      cart = cart_fixture(scope, item, 2)

      assert {:ok, order} = Ordering.checkout(scope, cart)

      assert order.status == :pending_payment
      assert order.number == 1
      assert order.kind == :dine_in
      assert Money.equal?(order.total, Money.new!(:USD, "7.00"))
      assert [order_item] = order.items
      assert order_item.name_snapshot == "Latte"
      assert Money.equal?(order_item.unit_price_snapshot, Money.new!(:USD, "3.50"))
      assert order_item.qty == 2
    end

    test "the source cart is marked converted", %{scope: scope, item: item} do
      cart = cart_fixture(scope, item)
      {:ok, _order} = Ordering.checkout(scope, cart)

      assert Ordering.get_active_cart(scope, cart.guest_token) == nil
    end

    test "order numbers increment per venue per business day, starting at 1", %{
      scope: scope,
      item: item
    } do
      cart_a = cart_fixture(scope, item)
      cart_b = cart_fixture(scope, item)

      {:ok, order_a} = Ordering.checkout(scope, cart_a)
      {:ok, order_b} = Ordering.checkout(scope, cart_b)

      assert order_a.number == 1
      assert order_b.number == 2
    end

    test "a menu item's later price change never affects an already-checked-out order", %{
      scope: scope,
      item: item
    } do
      cart = cart_fixture(scope, item)
      {:ok, order} = Ordering.checkout(scope, cart)

      {:ok, _} = Catalog.update_item(scope, item, %{"price" => Money.new!(:USD, "99.00")})

      order = Repo.preload(order, :items, force: true)
      [order_item] = order.items
      assert Money.equal?(order_item.unit_price_snapshot, Money.new!(:USD, "3.50"))
    end
  end

  describe "checkout/2 — gates" do
    test "an empty cart is rejected", %{scope: scope, item: item} do
      cart = cart_fixture(scope, item)
      [line] = cart.items
      :ok = Ordering.remove_item(scope, line)
      cart = Ordering.get_active_cart(scope, cart.guest_token)

      assert {:error, :empty_cart} = Ordering.checkout(scope, cart)
    end

    test "a paused venue rejects checkout", %{scope: scope, venue: venue, item: item} do
      cart = cart_fixture(scope, item)
      {:ok, venue} = Tenants.pause_ordering(scope, venue, 20)
      scope = %{scope | venue: venue}

      assert {:error, :ordering_paused} = Ordering.checkout(scope, cart)
    end

    test "a closed venue (outside configured opening_hours) rejects checkout", %{
      scope: scope,
      venue: venue,
      item: item
    } do
      cart = cart_fixture(scope, item)
      # A schedule that's never open — every day empty.
      hours =
        for day <- ~w(monday tuesday wednesday thursday friday saturday sunday),
            into: %{},
            do: {day, []}

      {:ok, venue} = venue |> Ecto.Changeset.change(opening_hours: hours) |> Repo.update()
      scope = %{scope | venue: venue}

      assert {:error, :venue_closed} = Ordering.checkout(scope, cart)
    end

    test "a structurally invalid line blocks checkout (design-qa.md Q42)", %{
      scope: scope,
      item: item
    } do
      {:ok, group} =
        Catalog.create_modifier_group(scope, %{
          "name" => "Size",
          "min_selections" => 0,
          "max_selections" => 1
        })

      {:ok, _option} =
        Catalog.create_modifier_option(scope, group, %{
          "name" => "Small",
          "price_delta" => Money.new!(:USD, "0")
        })

      {:ok, _} = Catalog.attach_group_to_item(scope, item, group)
      cart = cart_fixture(scope, item)

      {:ok, _} =
        Catalog.update_modifier_group(scope, group, %{"min_selections" => 1, "required" => true})

      cart = Ordering.get_active_cart(scope, cart.guest_token)

      assert {:error, :items_changed} = Ordering.checkout(scope, cart)
      # Untouched — still active, not converted, so the customer can fix it.
      assert Ordering.get_active_cart(scope, cart.guest_token).status == :active
    end

    test "too many concurrent active orders for the same guest is rejected", %{
      scope: scope,
      item: item
    } do
      token = Cart.generate_guest_token()

      for _ <- 1..5 do
        {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
        {:ok, _order} = Ordering.checkout(scope, cart)
      end

      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
      assert {:error, :too_many_active_orders} = Ordering.checkout(scope, cart)
    end
  end

  describe "checkout/2 — daily-limit hold (design-qa.md Q1)" do
    test "reserves reserved_qty atomically at checkout, before any payment", %{
      scope: scope,
      item: item
    } do
      {:ok, _} = Catalog.set_daily_limit(scope, item, 5)
      cart = cart_fixture(scope, item, 3)

      {:ok, _order} = Ordering.checkout(scope, cart)

      limit = Catalog.get_daily_limit(scope, item)
      assert limit.reserved_qty == 3
      assert limit.sold_qty == 0
    end

    test "sold-out is rejected before checkout succeeds, no partial order left behind", %{
      scope: scope,
      item: item
    } do
      {:ok, _} = Catalog.set_daily_limit(scope, item, 2)
      cart = cart_fixture(scope, item, 3)

      assert {:error, :sold_out} = Ordering.checkout(scope, cart)
      # The limit row is untouched — no partial hold left by the failed attempt.
      limit = Catalog.get_daily_limit(scope, item)
      assert limit.reserved_qty == 0
      # The cart survives, unconverted, so the customer can adjust qty and retry.
      assert Ordering.get_active_cart(scope, cart.guest_token).status == :active
    end

    test "an unlimited item (no daily_item_limit row) checks out with no hold at all", %{
      scope: scope,
      item: item
    } do
      cart = cart_fixture(scope, item, 20)
      assert {:ok, _order} = Ordering.checkout(scope, cart)
      assert Catalog.get_daily_limit(scope, item) == nil
    end
  end

  describe "checkout/2 — two simultaneous checkouts for the last limited portion (build-plan.md Feature 08 verify step)" do
    test "exactly one reaches pending_payment, the other sees sold-out — never both, never neither",
         %{
           scope: scope,
           org: org,
           item: item
         } do
      {:ok, _} = Catalog.set_daily_limit(scope, item, 1)

      cart_a = cart_fixture(scope, item, 1)
      cart_b = cart_fixture(scope, item, 1)

      parent = self()

      task_a =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          Repo.put_org_id(org.id)
          Ordering.checkout(scope, cart_a)
        end)

      task_b =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          Repo.put_org_id(org.id)
          Ordering.checkout(scope, cart_b)
        end)

      results = [Task.await(task_a), Task.await(task_b)]

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :sold_out}, &1)) == 1

      # The limit row proves it too, independent of which task "won":
      # exactly 1 reserved, never 2 (never both charged the customer for
      # stock that isn't there) and never 0 (the winner's hold is real).
      limit = Catalog.get_daily_limit(scope, item)
      assert limit.reserved_qty == 1
      assert limit.sold_qty == 0
    end

    test "hammering 10 concurrent checkouts against a limit of 3 — exactly 3 win", %{
      scope: scope,
      org: org,
      item: item
    } do
      {:ok, _} = Catalog.set_daily_limit(scope, item, 3)
      parent = self()

      results =
        1..10
        |> Task.async_stream(
          fn _ ->
            Sandbox.allow(Repo, parent, self())
            Repo.put_org_id(org.id)
            cart = cart_fixture(scope, item, 1)
            Ordering.checkout(scope, cart)
          end,
          max_concurrency: 10
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 3
      assert Enum.count(results, &match?({:error, :sold_out}, &1)) == 7

      limit = Catalog.get_daily_limit(scope, item)
      assert limit.reserved_qty == 3
    end
  end
end

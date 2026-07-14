defmodule Tabletap.Ordering.ServeConfirmationTest do
  @moduledoc """
  Build-plan.md Feature 11 — QR-scan/manual serve confirm, stock
  deduction (`Inventory.deduct_for_order/2` wired into the `served`
  transition), pickup no-show flagging + resolution, and the two sweep
  workers (pickup no-show, 24h auto-close). Provider calls mocked via
  `Payments.ProviderMock` (Mox), same as payments_test.exs — no test
  hits a real provider API (code-standards.md).
  """
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Ecto.Query
  import Mox
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Inventory.{Ingredient, RecipeLine, StockMovement}
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, Order, OrderStateMachine}
  alias Tabletap.Ordering.Workers.{AutoCloseServedOrders, SweepPickupNoShows}
  alias Tabletap.Payments
  alias Tabletap.Payments.{Payment, ProviderMock}
  alias Tabletap.Repo

  setup :verify_on_exit!

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

  defp ready_order(scope, item, opts \\ []) do
    qty = Keyword.get(opts, :qty, 1)
    table_id = Keyword.get(opts, :table_id)
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, table_id, item, [], qty, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    {:ok, order} = OrderStateMachine.transition(scope, order, :placed)
    {:ok, order} = OrderStateMachine.transition(scope, order, :accepted)
    {:ok, order} = OrderStateMachine.transition(scope, order, :preparing)
    {:ok, order} = OrderStateMachine.transition(scope, order, :ready)
    Ordering.get_order(scope, order.id)
  end

  defp ingredient_fixture(scope, attrs \\ %{}) do
    %Ingredient{}
    |> Ecto.Changeset.change(
      Enum.into(attrs, %{
        org_id: scope.org.id,
        venue_id: scope.venue.id,
        name: "Milk",
        unit: :ml,
        stock_qty: Decimal.new(10_000)
      })
    )
    |> Repo.insert!()
  end

  defp recipe_line_fixture(scope, item, ingredient, qty_per_serving) do
    %RecipeLine{}
    |> Ecto.Changeset.change(%{
      org_id: scope.org.id,
      menu_item_id: item.id,
      ingredient_id: ingredient.id,
      qty_per_serving: Decimal.new(qty_per_serving)
    })
    |> Repo.insert!()
  end

  defp comp_payment_fixture(scope, order) do
    %Payment{}
    |> Ecto.Changeset.change(%{
      org_id: scope.org.id,
      venue_id: scope.venue.id,
      order_id: order.id,
      provider: :comp,
      status: :succeeded,
      amount: order.total,
      wallet_msisdn_masked: nil
    })
    |> Repo.insert!()
  end

  describe "served transition — stock deduction (Inventory.deduct_for_order/2)" do
    test "writes a stock_movements row and decrements ingredient stock_qty", %{
      scope: scope,
      item: item
    } do
      milk = ingredient_fixture(scope)
      recipe_line_fixture(scope, item, milk, "200")

      order = ready_order(scope, item, qty: 3)
      assert {:ok, served} = OrderStateMachine.transition(scope, order, :served)
      assert served.status == :served

      movement = Repo.one(from(m in StockMovement, where: m.order_id == ^order.id))
      assert movement.ingredient_id == milk.id
      assert movement.reason == :sale
      assert Decimal.equal?(movement.qty_delta, Decimal.new("-600"))

      reloaded_milk = Repo.get(Ingredient, milk.id)
      assert Decimal.equal?(reloaded_milk.stock_qty, Decimal.new("9400"))
    end

    test "an un-reciped item deducts nothing — correct no-op, not an error", %{
      scope: scope,
      item: item
    } do
      order = ready_order(scope, item)
      assert {:ok, served} = OrderStateMachine.transition(scope, order, :served)
      assert served.status == :served
      assert Repo.aggregate(from(m in StockMovement), :count) == 0
    end
  end

  describe "confirm_served_by_scan/3 (Q18)" do
    test "the right table's qr_token flips the order to served", %{scope: scope, item: item} do
      table = table_fixture(scope)
      order = ready_order(scope, item, table_id: table.id)

      assert {:ok, served} = Ordering.confirm_served_by_scan(scope, order, table.qr_token)
      assert served.status == :served
    end

    test "the wrong table's qr_token is rejected with a clear error, order untouched", %{
      scope: scope,
      item: item
    } do
      table = table_fixture(scope)
      other_table = table_fixture(scope)
      order = ready_order(scope, item, table_id: table.id)

      assert {:error, :token_mismatch} =
               Ordering.confirm_served_by_scan(scope, order, other_table.qr_token)

      assert Repo.get(Order, order.id).status == :ready
    end

    test "a takeaway order (no table) matches the customer's guest_token instead", %{
      scope: scope,
      item: item
    } do
      order = ready_order(scope, item)

      assert {:error, :token_mismatch} = Ordering.confirm_served_by_scan(scope, order, "wrong")
      assert {:ok, served} = Ordering.confirm_served_by_scan(scope, order, order.guest_token)
      assert served.status == :served
    end

    test "a pickup-mode venue always matches guest_token, even if the order has a table", %{
      scope: scope,
      venue: venue,
      item: item
    } do
      {:ok, venue} = venue |> Ecto.Changeset.change(fulfillment_mode: :pickup) |> Repo.update()
      scope = %{scope | venue: venue}
      table = table_fixture(scope)
      order = ready_order(scope, item, table_id: table.id)

      assert {:error, :token_mismatch} =
               Ordering.confirm_served_by_scan(scope, order, table.qr_token)

      assert {:ok, served} = Ordering.confirm_served_by_scan(scope, order, order.guest_token)
      assert served.status == :served
    end

    test "a non-ready order is rejected", %{scope: scope, item: item} do
      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(scope, cart)

      assert {:error, :not_ready} =
               Ordering.confirm_served_by_scan(scope, order, order.guest_token)
    end
  end

  describe "confirm_served_manually/2 (Q19)" do
    test "manager override serves without a scan and clears any existing flag", %{
      scope: scope,
      item: item
    } do
      order = ready_order(scope, item)
      {:ok, flagged} = Ordering.mark_unserveable(scope, order)
      assert flagged.flag == :unserveable

      assert {:ok, served} = Ordering.confirm_served_manually(scope, flagged)
      assert served.status == :served
      assert served.flag == nil
    end

    test "rejects a non-ready order", %{scope: scope, item: item} do
      order = ready_order(scope, item)
      {:ok, served} = OrderStateMachine.transition(scope, order, :served)

      assert {:error, :not_ready} = Ordering.confirm_served_manually(scope, served)
    end
  end

  describe "mark_not_picked_up/2 (Q32)" do
    test "flags the order without touching its status", %{scope: scope, item: item} do
      order = ready_order(scope, item)

      assert {:ok, flagged} = Ordering.mark_not_picked_up(scope, order)
      assert flagged.flag == :not_picked_up
      assert flagged.flagged_at
      assert flagged.status == :ready
    end
  end

  describe "flag resolution (Q9/Q10/Q32)" do
    test "resolve_flag_refund/3 settles a comp order without calling the provider", %{
      scope: scope,
      item: item
    } do
      order = ready_order(scope, item)
      {:ok, flagged} = Ordering.mark_unserveable(scope, order)
      comp_payment_fixture(scope, order)

      assert {:ok, refunded} = Ordering.resolve_flag_refund(scope, flagged, nil)
      assert refunded.status == :refunded
      assert refunded.flag == nil
    end

    test "resolve_flag_refund/3 refunds a real payment through the provider", %{
      scope: scope,
      venue: venue,
      item: item
    } do
      venue = charges_enabled_venue_fixture(venue)
      scope = %{scope | venue: venue}

      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
      {:ok, pending} = Ordering.checkout(scope, cart)
      {:ok, payment} = Payments.charge_order(scope, pending, "252611111111")

      expect(ProviderMock, :refund, fn _creds, _txn, _amount ->
        {:ok, %{provider_refund_id: "refund-1"}}
      end)

      {:ok, _} = Payments.confirm_approved(payment.id, "waafi-txn-serve-1")
      order = Ordering.get_order(scope, pending.id)
      {:ok, order} = OrderStateMachine.transition(scope, order, :accepted)
      {:ok, order} = OrderStateMachine.transition(scope, order, :preparing)
      {:ok, order} = OrderStateMachine.transition(scope, order, :ready)
      {:ok, flagged} = Ordering.mark_not_picked_up(scope, order)

      staff = accounts_fixture_user()

      assert {:ok, refunded} = Ordering.resolve_flag_refund(scope, flagged, staff.id)
      assert refunded.status == :refunded
      assert refunded.flag == nil
    end

    test "resolve_flag_refund/3 errors cleanly when there's no payment at all", %{
      scope: scope,
      item: item
    } do
      order = ready_order(scope, item)
      {:ok, flagged} = Ordering.mark_unserveable(scope, order)

      assert {:error, :no_payment} = Ordering.resolve_flag_refund(scope, flagged, nil)
    end

    test "convert_to_takeaway/2 drops the assignment and clears the flag", %{
      scope: scope,
      item: item
    } do
      table = table_fixture(scope)
      order = ready_order(scope, item, table_id: table.id)
      {:ok, flagged} = Ordering.mark_unserveable(scope, order)

      assert {:ok, converted} = Ordering.convert_to_takeaway(scope, flagged)
      assert converted.kind == :takeaway
      assert converted.waiter_membership_id == nil
      assert converted.flag == nil
      assert converted.status == :ready
    end

    test "mark_collected/2 serves the order (stock deducts) and clears the flag", %{
      scope: scope,
      item: item
    } do
      milk = ingredient_fixture(scope)
      recipe_line_fixture(scope, item, milk, "200")

      order = ready_order(scope, item)
      {:ok, flagged} = Ordering.mark_not_picked_up(scope, order)

      assert {:ok, collected} = Ordering.mark_collected(scope, flagged)
      assert collected.status == :served
      assert collected.flag == nil
      assert Repo.aggregate(from(m in StockMovement, where: m.order_id == ^order.id), :count) == 1
    end

    test "close_as_wasted/2 serves then closes, no refund", %{scope: scope, item: item} do
      order = ready_order(scope, item)
      {:ok, flagged} = Ordering.mark_not_picked_up(scope, order)

      assert {:ok, closed} = Ordering.close_as_wasted(scope, flagged)
      assert closed.status == :closed
      assert closed.flag == nil
      assert Repo.aggregate(from(p in Payment, where: p.order_id == ^order.id), :count) == 0
    end
  end

  describe "Workers.SweepPickupNoShows" do
    test "flags a pickup-mode order that's sat ready past the timeout", %{
      scope: scope,
      venue: venue,
      item: item
    } do
      {:ok, venue} =
        venue
        |> Ecto.Changeset.change(fulfillment_mode: :pickup, pickup_timeout_minutes: 15)
        |> Repo.update()

      scope = %{scope | venue: venue}
      order = ready_order(scope, item)

      stale_ready_at = DateTime.add(DateTime.utc_now(:second), -20 * 60, :second)

      {1, _} =
        Repo.update_all(from(o in Order, where: o.id == ^order.id),
          set: [ready_at: stale_ready_at]
        )

      assert :ok = perform_job(SweepPickupNoShows, %{})

      reloaded = Repo.get(Order, order.id)
      assert reloaded.flag == :not_picked_up
    end

    test "a not-yet-timed-out order is left alone", %{scope: scope, venue: venue, item: item} do
      {:ok, venue} =
        venue
        |> Ecto.Changeset.change(fulfillment_mode: :pickup, pickup_timeout_minutes: 15)
        |> Repo.update()

      scope = %{scope | venue: venue}
      order = ready_order(scope, item)

      assert :ok = perform_job(SweepPickupNoShows, %{})
      assert Repo.get(Order, order.id).flag == nil
    end

    test "a waiter-mode venue's ready order is never flagged", %{scope: scope, item: item} do
      order = ready_order(scope, item)

      stale_ready_at = DateTime.add(DateTime.utc_now(:second), -60 * 60, :second)

      {1, _} =
        Repo.update_all(from(o in Order, where: o.id == ^order.id),
          set: [ready_at: stale_ready_at]
        )

      assert :ok = perform_job(SweepPickupNoShows, %{})
      assert Repo.get(Order, order.id).flag == nil
    end
  end

  describe "Workers.AutoCloseServedOrders" do
    test "closes a served order past the 24h rating window", %{scope: scope, item: item} do
      order = ready_order(scope, item)
      {:ok, order} = OrderStateMachine.transition(scope, order, :served)

      stale_served_at = DateTime.add(DateTime.utc_now(:second), -25 * 60 * 60, :second)

      {1, _} =
        Repo.update_all(from(o in Order, where: o.id == ^order.id),
          set: [served_at: stale_served_at]
        )

      assert :ok = perform_job(AutoCloseServedOrders, %{})
      assert Repo.get(Order, order.id).status == :closed
    end

    test "a recently-served order stays served", %{scope: scope, item: item} do
      order = ready_order(scope, item)
      {:ok, order} = OrderStateMachine.transition(scope, order, :served)

      assert :ok = perform_job(AutoCloseServedOrders, %{})
      assert Repo.get(Order, order.id).status == :served
    end
  end

  # Minimal inline user fixture — AccountsFixtures.user_fixture/0 already
  # exists (waiter_fixture/2 uses it) but isn't imported here; this test
  # file only needs a bare `staff_user_id` to attribute a refund to.
  defp accounts_fixture_user, do: Tabletap.AccountsFixtures.user_fixture()
end

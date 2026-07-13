defmodule Tabletap.Ordering.OrderStateMachineTest do
  use Tabletap.DataCase, async: true

  import Ecto.Query

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Repo}
  alias Tabletap.Ordering.{Order, OrderItem, OrderStateMachine}

  import Tabletap.TenantsFixtures

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue, role: :manager}

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    %{scope: scope, org: org, venue: venue, item: item}
  end

  # The state machine's own documented forward path (OrderStateMachine
  # moduledoc) — the sequence `advance_to/3` walks through
  # `OrderStateMachine.transition/3` to reach a target status.
  @forward_path [:placed, :accepted, :preparing, :ready, :served, :closed]

  # Inserts a fresh `pending_payment` order — the one real entry point
  # (mirrors `Ordering.checkout/2`'s own `Order.new_changeset/1` call) —
  # then drives it to `status` via real `OrderStateMachine.transition/3`
  # calls. Never a direct changeset write on `:status` past creation
  # (code-standards.md: "direct status updates are forbidden, including
  # in tests — use the machine or fixtures that use it").
  defp order_fixture(scope, status, item, qty \\ 1) do
    now = DateTime.utc_now(:second)
    business_date = Tabletap.Tenants.business_date(scope.venue, now)

    {:ok, order} =
      %{
        org_id: scope.org.id,
        venue_id: scope.venue.id,
        guest_token: "guest-#{System.unique_integer([:positive])}",
        number: System.unique_integer([:positive]),
        business_date: business_date,
        kind: :dine_in,
        subtotal: Money.mult!(item.price, qty),
        discount_total: Money.new!(item.price.currency, 0),
        total: Money.mult!(item.price, qty)
      }
      |> Order.new_changeset()
      |> Repo.insert()

    {:ok, _order_item} =
      %OrderItem{}
      |> Ecto.Changeset.change(%{
        org_id: scope.org.id,
        order_id: order.id,
        menu_item_id: item.id,
        name_snapshot: item.name,
        unit_price_snapshot: item.price,
        qty: qty,
        line_total: Money.mult!(item.price, qty)
      })
      |> Repo.insert()

    order |> Repo.preload(:items) |> advance_to(scope, status)
  end

  defp advance_to(order, _scope, :pending_payment), do: order

  defp advance_to(order, scope, status) when status in [:expired, :cancelled] do
    {:ok, order} = OrderStateMachine.transition(scope, order, status)
    order
  end

  defp advance_to(order, scope, status) do
    steps = Enum.take_while(@forward_path, &(&1 != status)) ++ [status]

    Enum.reduce(steps, order, fn step, order ->
      {:ok, order} = OrderStateMachine.transition(scope, order, step)
      order
    end)
  end

  defp limit_row(scope, item, business_date) do
    Catalog.get_daily_limit(scope, item, business_date)
  end

  describe "legal?/2 and legal_transitions/1" do
    test "the documented transition table is exactly what's enforced" do
      assert OrderStateMachine.legal_transitions(:pending_payment) == [
               :placed,
               :expired,
               :cancelled
             ]

      assert OrderStateMachine.legal_transitions(:placed) == [:accepted, :cancelled, :refunded]
      assert OrderStateMachine.legal_transitions(:accepted) == [:preparing, :cancelled, :refunded]
      assert OrderStateMachine.legal_transitions(:preparing) == [:ready, :accepted, :refunded]
      assert OrderStateMachine.legal_transitions(:ready) == [:served, :preparing, :refunded]
      assert OrderStateMachine.legal_transitions(:served) == [:closed, :refunded]
      assert OrderStateMachine.legal_transitions(:closed) == [:refunded]
      assert OrderStateMachine.legal_transitions(:expired) == []
      assert OrderStateMachine.legal_transitions(:cancelled) == []
      assert OrderStateMachine.legal_transitions(:refunded) == []
    end

    test "served is irreversible — no path back to ready" do
      refute OrderStateMachine.legal?(:served, :ready)
      refute OrderStateMachine.legal?(:served, :preparing)
      refute OrderStateMachine.legal?(:served, :accepted)
    end

    test "cancelled is only legal pre-kitchen (not once preparing has started)" do
      assert OrderStateMachine.legal?(:accepted, :cancelled)
      refute OrderStateMachine.legal?(:preparing, :cancelled)
      refute OrderStateMachine.legal?(:ready, :cancelled)
      refute OrderStateMachine.legal?(:served, :cancelled)
    end
  end

  describe "transition/3 — illegal moves raise" do
    test "skipping straight to accepted from pending_payment", %{scope: scope, item: item} do
      order = order_fixture(scope, :pending_payment, item)

      assert_raise ArgumentError, ~r/illegal order transition/, fn ->
        OrderStateMachine.transition(scope, order, :accepted)
      end
    end

    test "reopening a closed order to preparing", %{scope: scope, item: item} do
      order = order_fixture(scope, :closed, item)
      assert_raise ArgumentError, fn -> OrderStateMachine.transition(scope, order, :preparing) end
    end

    test "no such thing as un-expiring", %{scope: scope, item: item} do
      order = order_fixture(scope, :expired, item)
      assert_raise ArgumentError, fn -> OrderStateMachine.transition(scope, order, :placed) end
    end
  end

  describe "transition/3 — pending_payment -> placed converts the hold (design-qa.md Q1)" do
    test "reserved_qty moves to sold_qty", %{scope: scope, item: item} do
      {:ok, _} = Catalog.set_daily_limit(scope, item, 10)
      business_date = Tabletap.Tenants.business_date(scope.venue)

      Repo.update_all(
        from(l in Catalog.DailyItemLimit, where: l.item_id == ^item.id),
        inc: [reserved_qty: 3]
      )

      order = order_fixture(scope, :pending_payment, item, 3)
      assert {:ok, updated} = OrderStateMachine.transition(scope, order, :placed)

      assert updated.status == :placed
      assert updated.placed_at

      limit = limit_row(scope, item, business_date)
      assert limit.reserved_qty == 0
      assert limit.sold_qty == 3
    end

    test "an unlimited item (no daily_item_limit row at all) is a harmless no-op", %{
      scope: scope,
      item: item
    } do
      order = order_fixture(scope, :pending_payment, item, 2)
      assert {:ok, updated} = OrderStateMachine.transition(scope, order, :placed)
      assert updated.status == :placed
    end
  end

  describe "transition/3 — pending_payment -> expired/cancelled releases the hold, never sells it" do
    test "expired releases reserved_qty without touching sold_qty", %{scope: scope, item: item} do
      {:ok, _} = Catalog.set_daily_limit(scope, item, 10)
      business_date = Tabletap.Tenants.business_date(scope.venue)

      Repo.update_all(from(l in Catalog.DailyItemLimit, where: l.item_id == ^item.id),
        inc: [reserved_qty: 2]
      )

      order = order_fixture(scope, :pending_payment, item, 2)
      assert {:ok, updated} = OrderStateMachine.transition(scope, order, :expired)
      assert updated.status == :expired

      limit = limit_row(scope, item, business_date)
      assert limit.reserved_qty == 0
      assert limit.sold_qty == 0
    end

    test "cancelled releases the hold the same way", %{scope: scope, item: item} do
      {:ok, _} = Catalog.set_daily_limit(scope, item, 10)
      business_date = Tabletap.Tenants.business_date(scope.venue)

      Repo.update_all(from(l in Catalog.DailyItemLimit, where: l.item_id == ^item.id),
        inc: [reserved_qty: 1]
      )

      order = order_fixture(scope, :pending_payment, item, 1)
      assert {:ok, _updated} = OrderStateMachine.transition(scope, order, :cancelled)

      limit = limit_row(scope, item, business_date)
      assert limit.reserved_qty == 0
    end
  end

  describe "transition/3 — forward timestamps" do
    test "placed -> accepted sets accepted_at", %{scope: scope, item: item} do
      order = order_fixture(scope, :placed, item)
      assert {:ok, updated} = OrderStateMachine.transition(scope, order, :accepted)
      assert updated.accepted_at
    end

    test "accepted -> preparing has no dedicated timestamp column", %{scope: scope, item: item} do
      order = order_fixture(scope, :accepted, item)
      assert {:ok, updated} = OrderStateMachine.transition(scope, order, :preparing)
      assert updated.status == :preparing
    end

    test "preparing -> ready sets ready_at", %{scope: scope, item: item} do
      order = order_fixture(scope, :preparing, item)
      assert {:ok, updated} = OrderStateMachine.transition(scope, order, :ready)
      assert updated.ready_at
    end

    test "ready -> served sets served_at", %{scope: scope, item: item} do
      order = order_fixture(scope, :ready, item)
      assert {:ok, updated} = OrderStateMachine.transition(scope, order, :served)
      assert updated.served_at
    end

    test "served -> closed sets closed_at", %{scope: scope, item: item} do
      order = order_fixture(scope, :served, item)
      assert {:ok, updated} = OrderStateMachine.transition(scope, order, :closed)
      assert updated.closed_at
    end
  end

  describe "transition/3 — one-step-back undo (design-qa.md Q25)" do
    test "ready -> preparing clears ready_at (retracts the pickup notification)", %{
      scope: scope,
      item: item
    } do
      order = order_fixture(scope, :ready, item)

      {:ok, order} =
        Repo.update(Ecto.Changeset.change(order, ready_at: DateTime.utc_now(:second)))

      order = Repo.preload(order, :items)

      assert {:ok, updated} = OrderStateMachine.transition(scope, order, :preparing)
      assert updated.status == :preparing
      assert updated.ready_at == nil
    end

    test "preparing -> accepted undoes the kitchen start", %{scope: scope, item: item} do
      order = order_fixture(scope, :preparing, item)
      assert {:ok, updated} = OrderStateMachine.transition(scope, order, :accepted)
      assert updated.status == :accepted
    end
  end

  describe "telemetry (code-standards.md exact event names)" do
    test "every transition emits [:tabletap, :order, :transition]", %{scope: scope, item: item} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:tabletap, :order, :transition]])
      order = order_fixture(scope, :placed, item)

      {:ok, _} = OrderStateMachine.transition(scope, order, :accepted)

      assert_received {[:tabletap, :order, :transition], ^ref, %{},
                       %{order_id: order_id, from: :placed, to: :accepted, actor_role: :manager}}

      assert order_id == order.id
    end

    test "reaching :placed also emits [:tabletap, :order, :placed]", %{scope: scope, item: item} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:tabletap, :order, :placed]])
      order = order_fixture(scope, :pending_payment, item)

      {:ok, _} = OrderStateMachine.transition(scope, order, :placed)

      assert_received {[:tabletap, :order, :placed], ^ref, %{}, %{order_id: order_id}}
      assert order_id == order.id
    end

    test "reaching :served also emits [:tabletap, :order, :served] with the accept-to-served duration",
         %{
           scope: scope,
           item: item
         } do
      ref = :telemetry_test.attach_event_handlers(self(), [[:tabletap, :order, :served]])
      order = order_fixture(scope, :ready, item)
      accepted_at = DateTime.add(DateTime.utc_now(:second), -60, :second)
      {:ok, order} = Repo.update(Ecto.Changeset.change(order, accepted_at: accepted_at))
      order = Repo.preload(order, :items)

      {:ok, _} = OrderStateMachine.transition(scope, order, :served)

      assert_received {[:tabletap, :order, :served], ^ref, %{}, %{accept_to_served_ms: ms}}
      assert ms >= 60_000
    end
  end

  describe "PubSub broadcast-after-commit" do
    test "a successful transition broadcasts :order_updated on order:<id>", %{
      scope: scope,
      item: item
    } do
      order = order_fixture(scope, :placed, item)
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "order:#{order.id}")

      {:ok, _} = OrderStateMachine.transition(scope, order, :accepted)

      assert_received :order_updated
    end

    test "an illegal transition (raises before any transaction) never broadcasts", %{
      scope: scope,
      item: item
    } do
      order = order_fixture(scope, :pending_payment, item)
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "order:#{order.id}")

      assert_raise ArgumentError, fn -> OrderStateMachine.transition(scope, order, :served) end
      refute_received :order_updated
    end
  end
end

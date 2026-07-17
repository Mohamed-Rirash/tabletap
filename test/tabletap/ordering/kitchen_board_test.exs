defmodule Tabletap.Ordering.KitchenBoardTest do
  @moduledoc """
  Build-plan.md Feature 14 — the kitchen's context API: board reads,
  Start/Ready advances (a `placed` Start passes through `accepted`),
  Q25 one-step-back undo, the per-ticket overdue threshold, and the
  "waiter notified on ready" broadcast plus its undo retraction.
  """
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Order, OrderItem, OrderStateMachine}
  alias Tabletap.Repo

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue, role: :kitchen}

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Mains"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Burger",
        "price" => Money.new!(:USD, "5.00"),
        "prep_minutes" => 12
      })

    %{scope: scope, org: org, venue: venue, category: category, item: item}
  end

  # Same shape as order_state_machine_test's fixture: insert the one real
  # entry state (`pending_payment`), then drive to `status` via real
  # transitions — never a direct `:status` write (code-standards.md).
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

  @forward_path [:placed, :accepted, :preparing, :ready, :served]

  defp advance_to(order, _scope, :pending_payment), do: order

  defp advance_to(order, scope, target) do
    steps = Enum.take_while(@forward_path, &(&1 != target)) ++ [target]

    Enum.reduce(steps, order, fn status, acc ->
      {:ok, moved} = OrderStateMachine.transition(scope, acc, status)
      moved
    end)
  end

  describe "kitchen_start_order/2" do
    test "a placed ticket passes through accepted on its way to preparing", %{
      scope: scope,
      item: item
    } do
      order = order_fixture(scope, :placed, item)

      assert {:ok, %Order{status: :preparing} = started} =
               Ordering.kitchen_start_order(scope, order)

      # Starting to cook *is* acceptance — the intermediate hop leaves a
      # real accepted_at behind, not a skipped-over hole.
      assert started.accepted_at
    end

    test "an accepted ticket goes straight to preparing", %{scope: scope, item: item} do
      order = order_fixture(scope, :accepted, item)

      assert {:ok, %Order{status: :preparing}} = Ordering.kitchen_start_order(scope, order)
    end

    test "a ticket that already moved on is stale, never a crash", %{scope: scope, item: item} do
      preparing = order_fixture(scope, :preparing, item)
      ready = order_fixture(scope, :ready, item)

      assert {:error, :stale} = Ordering.kitchen_start_order(scope, preparing)
      assert {:error, :stale} = Ordering.kitchen_start_order(scope, ready)
    end
  end

  describe "kitchen_mark_ready/2" do
    test "preparing → ready", %{scope: scope, item: item} do
      order = order_fixture(scope, :preparing, item)

      assert {:ok, %Order{status: :ready} = ready} = Ordering.kitchen_mark_ready(scope, order)
      assert ready.ready_at
    end

    test "anything else is stale", %{scope: scope, item: item} do
      order = order_fixture(scope, :placed, item)

      assert {:error, :stale} = Ordering.kitchen_mark_ready(scope, order)
    end
  end

  describe "kitchen_undo/2 (design-qa.md Q25)" do
    test "ready → preparing retracts ready_at with it", %{scope: scope, item: item} do
      order = order_fixture(scope, :ready, item)

      assert {:ok, %Order{status: :preparing} = undone} = Ordering.kitchen_undo(scope, order)
      assert undone.ready_at == nil
    end

    test "preparing → accepted", %{scope: scope, item: item} do
      order = order_fixture(scope, :preparing, item)

      assert {:ok, %Order{status: :accepted}} = Ordering.kitchen_undo(scope, order)
    end

    test "accepted and served have no backward step", %{scope: scope, item: item} do
      accepted = order_fixture(scope, :accepted, item)
      served = order_fixture(scope, :served, item)

      assert {:error, :stale} = Ordering.kitchen_undo(scope, accepted)
      assert {:error, :stale} = Ordering.kitchen_undo(scope, served)
    end
  end

  describe "list_kitchen_orders/1 and get_kitchen_order/2" do
    test "lists only in-flight orders, oldest placed first", %{scope: scope, item: item} do
      placed = order_fixture(scope, :placed, item)
      preparing = order_fixture(scope, :preparing, item)
      _pending = order_fixture(scope, :pending_payment, item)
      _served = order_fixture(scope, :served, item)

      # Stagger placed_at (second-truncated timestamps tie within a fast
      # test) — a timestamp write, not a status write, so a direct change
      # is legal here.
      {:ok, _} =
        placed
        |> Ecto.Changeset.change(placed_at: DateTime.add(DateTime.utc_now(:second), -100))
        |> Repo.update()

      assert [first, second] = Ordering.list_kitchen_orders(scope)
      assert first.id == placed.id
      assert second.id == preparing.id
    end

    test "a second tenant sees nothing", %{scope: scope, item: item} do
      order_fixture(scope, :placed, item)

      %{org_b: org_b, venue_b: venue_b} = two_orgs()
      Repo.put_org_id(org_b.id)
      scope_b = %Scope{org: org_b, venue: venue_b, role: :kitchen}

      assert Ordering.list_kitchen_orders(scope_b) == []
    end

    test "get_kitchen_order/2 is nil for an unknown id or a no-longer-kitchen status", %{
      scope: scope,
      item: item
    } do
      served = order_fixture(scope, :served, item)
      placed = order_fixture(scope, :placed, item)

      assert Ordering.get_kitchen_order(scope, Ecto.UUID.generate()) == nil
      assert Ordering.get_kitchen_order(scope, served.id) == nil
      assert %Order{} = Ordering.get_kitchen_order(scope, placed.id)
    end
  end

  describe "expected_prep_minutes/1" do
    test "the slowest line wins (parallel prep), and no prep_minutes anywhere defaults to 10", %{
      scope: scope,
      category: category,
      item: item
    } do
      {:ok, slow} =
        Catalog.create_item(scope, category, %{
          "name" => "Roast",
          "price" => Money.new!(:USD, "9.00"),
          "prep_minutes" => 25
        })

      {:ok, untimed} =
        Catalog.create_item(scope, category, %{
          "name" => "Water",
          "price" => Money.new!(:USD, "1.00")
        })

      order = order_fixture(scope, :placed, item)

      {:ok, _} =
        %OrderItem{}
        |> Ecto.Changeset.change(%{
          org_id: scope.org.id,
          order_id: order.id,
          menu_item_id: slow.id,
          name_snapshot: slow.name,
          unit_price_snapshot: slow.price,
          qty: 1,
          line_total: slow.price
        })
        |> Repo.insert()

      assert order.id
             |> then(&Ordering.get_kitchen_order(scope, &1))
             |> Ordering.expected_prep_minutes() == 25

      untimed_order = order_fixture(scope, :placed, untimed)

      assert untimed_order.id
             |> then(&Ordering.get_kitchen_order(scope, &1))
             |> Ordering.expected_prep_minutes() == 10
    end
  end

  describe "broadcasts" do
    test "the venue orders topic carries the order id", %{scope: scope, venue: venue, item: item} do
      order = order_fixture(scope, :accepted, item)
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{venue.id}:orders")

      {:ok, _} = Ordering.kitchen_start_order(scope, order)

      order_id = order.id
      assert_received {:order_updated, ^order_id}
    end

    test "the assigned waiter hears ready, and the Q25 undo retracts it", %{
      scope: scope,
      org: org,
      venue: venue,
      item: item
    } do
      %{membership: membership} = waiter_fixture(org, venue)
      order = order_fixture(scope, :preparing, item)
      {:ok, order} = order |> Order.assign_waiter_changeset(membership.id) |> Repo.update()

      Phoenix.PubSub.subscribe(Tabletap.PubSub, "waiter:#{membership.id}")

      {:ok, ready} = Ordering.kitchen_mark_ready(scope, order)
      order_id = order.id
      assert_received {:order_ready, ^order_id}

      {:ok, _} = Ordering.kitchen_undo(scope, ready)
      assert_received {:order_ready_retracted, ^order_id}
    end

    test "an unassigned ready order notifies nobody", %{scope: scope, item: item} do
      order = order_fixture(scope, :preparing, item)
      {:ok, _} = Ordering.kitchen_mark_ready(scope, order)

      refute_received {:order_ready, _}
    end
  end
end

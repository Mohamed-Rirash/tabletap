defmodule Tabletap.Ordering.AssignmentTest do
  @moduledoc """
  The waiter-assignment algorithm (build-plan.md Feature 10;
  architecture.md "Waiter Assignment Algorithm"). Presence liveness is
  injected as a fun (`all_alive/2`) so no real Presence/Tracker process
  is needed. The claim-board race gets a dedicated concurrency test
  (code-standards.md "Race-sensitive paths ... get dedicated concurrency
  tests").
  """
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Ecto.Query
  import Tabletap.TenantsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Ordering, Repo, Staffing}
  alias Tabletap.Ordering.{Cart, Order, OrderStateMachine, WaiterCall}
  alias Tabletap.Ordering.Workers.{AssignWaiter, EscalateUnacceptedOrder}

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

  defp all_alive(_venue_id, _membership_id), do: true

  defp placed_order(scope, item, opts \\ []) do
    token = Cart.generate_guest_token()
    table_id = Keyword.get(opts, :table_id)
    {:ok, cart} = Ordering.add_to_cart(scope, token, table_id, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    {:ok, order} = OrderStateMachine.transition(scope, order, :placed)
    order
  end

  defp on_shift_waiter(scope) do
    %{membership: membership} = waiter_fixture(scope.org, scope.venue)
    waiter_scope = %{scope | membership: membership, role: :waiter}
    {:ok, _} = Staffing.clock_in(waiter_scope)
    %{membership: membership, scope: waiter_scope}
  end

  describe "assign_waiter/3 — the algorithm, step for step" do
    test "a pickup-mode venue skips assignment entirely (Q18)", %{
      scope: scope,
      venue: venue,
      item: item
    } do
      {:ok, venue} = venue |> Ecto.Changeset.change(fulfillment_mode: :pickup) |> Repo.update()
      scope = %{scope | venue: venue}
      %{membership: _waiter} = on_shift_waiter(scope)
      order = placed_order(scope, item)

      assert {:ok, :pickup_no_assignment} = Ordering.assign_waiter(scope, order, &all_alive/2)
      assert Repo.get(Order, order.id).waiter_membership_id == nil
    end

    test "a :counter walk-in order skips assignment too, even at a waiter-mode venue (Feature 15)",
         %{scope: scope, item: item} do
      %{membership: _waiter} = on_shift_waiter(scope)

      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
      {:ok, cart} = Ordering.set_kind(scope, cart, :counter)
      {:ok, order} = Ordering.checkout(scope, cart)
      {:ok, order} = OrderStateMachine.transition(scope, order, :placed)

      assert {:ok, :counter_no_assignment} = Ordering.assign_waiter(scope, order, &all_alive/2)
      assert Repo.get(Order, order.id).waiter_membership_id == nil
    end

    test "no waiters on shift → straight to the claim board, unassigned", %{
      scope: scope,
      item: item
    } do
      order = placed_order(scope, item)
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{scope.venue.id}:claim_board")

      assert {:ok, _} = Ordering.assign_waiter(scope, order, &all_alive/2)

      assert Repo.get(Order, order.id).waiter_membership_id == nil
      assert_received {:order_needs_claim, _id}
    end

    test "solo waiter on shift auto-accepts — no 90s window, no escalation job (Q49)", %{
      scope: scope,
      item: item
    } do
      %{membership: solo} = on_shift_waiter(scope)
      order = placed_order(scope, item)

      assert {:ok, accepted} = Ordering.assign_waiter(scope, order, &all_alive/2)

      assert accepted.status == :accepted
      assert Repo.get(Order, order.id).waiter_membership_id == solo.id
      refute_enqueued(worker: EscalateUnacceptedOrder, args: %{"order_id" => order.id})
    end

    test "two+ waiters: lowest open load wins, and a 90s escalation job is scheduled", %{
      scope: scope,
      item: item
    } do
      %{membership: busy, scope: busy_scope} = on_shift_waiter(scope)
      %{membership: free} = on_shift_waiter(scope)

      # Load up the first waiter with an accepted order.
      busy_order = placed_order(scope, item)
      {:ok, _} = Ordering.assign_waiter(scope, busy_order, fn _, id -> id == busy.id end)
      # (solo-shortcut auto-accepted it into `busy`'s queue)
      assert Repo.get(Order, busy_order.id).waiter_membership_id == busy.id
      _ = busy_scope

      order = placed_order(scope, item)
      assert {:ok, assigned} = Ordering.assign_waiter(scope, order, &all_alive/2)

      assert assigned.waiter_membership_id == free.id
      assert assigned.status == :placed

      assert_enqueued(
        worker: EscalateUnacceptedOrder,
        args: %{"order_id" => order.id, "assigned_membership_id" => free.id}
      )
    end

    test "assignment also enqueues a Web Push to the assigned waiter (build-plan.md Feature 20)",
         %{
           scope: scope,
           org: org,
           item: item
         } do
      %{membership: free} = on_shift_waiter(scope)
      order = placed_order(scope, item)

      assert {:ok, _assigned} = Ordering.assign_waiter(scope, order, &all_alive/2)

      assert_enqueued(
        worker: Tabletap.Notifications.Workers.SendPush,
        args: %{
          "type" => "waiter",
          "org_id" => org.id,
          "membership_id" => free.id,
          "title" => "New order",
          "body" => "Order ##{order.number}",
          "url" => "/waiter"
        }
      )
    end

    test "same-table stickiness overrides lowest load (Q8)", %{scope: scope, item: item} do
      %{membership: sticky_waiter} = on_shift_waiter(scope)
      %{membership: _idle_waiter} = on_shift_waiter(scope)
      table = table_fixture(scope)

      first = placed_order(scope, item, table_id: table.id)
      {:ok, _} = Ordering.assign_waiter(scope, first, fn _, id -> id == sticky_waiter.id end)
      assert Repo.get(Order, first.id).waiter_membership_id == sticky_waiter.id

      # The idle waiter has zero load — but the table already belongs to
      # sticky_waiter this sitting.
      second = placed_order(scope, item, table_id: table.id)
      assert {:ok, assigned} = Ordering.assign_waiter(scope, second, &all_alive/2)
      assert assigned.waiter_membership_id == sticky_waiter.id
    end

    test "a Presence-dead waiter is not a candidate even with an open shift (Q55)", %{
      scope: scope,
      item: item
    } do
      %{membership: dead} = on_shift_waiter(scope)
      %{membership: alive} = on_shift_waiter(scope)

      order = placed_order(scope, item)

      alive_fun = fn _venue_id, membership_id -> membership_id == alive.id end
      assert {:ok, assigned} = Ordering.assign_waiter(scope, order, alive_fun)

      # `alive` is the only live candidate → solo shortcut auto-accepts.
      assert assigned.waiter_membership_id == alive.id
      refute assigned.waiter_membership_id == dead.id
    end

    test "idempotent — an already-assigned or already-moved-on order is a no-op", %{
      scope: scope,
      item: item
    } do
      %{membership: waiter} = on_shift_waiter(scope)
      order = placed_order(scope, item)
      {:ok, accepted} = Ordering.assign_waiter(scope, order, &all_alive/2)

      assert {:ok, :already_resolved} = Ordering.assign_waiter(scope, accepted, &all_alive/2)

      still = Repo.get(Order, order.id)
      assert still.waiter_membership_id == waiter.id
    end
  end

  describe "Workers.AssignWaiter" do
    test "runs the algorithm from job args", %{scope: scope, org: org, item: item} do
      %{membership: solo} = on_shift_waiter(scope)
      order = placed_order(scope, item)

      # The state machine already enqueued this exact job at :placed —
      # perform it the way Oban would. (Presence has no tracked waiters
      # in test, so inject-free execution would hit the claim board; the
      # worker path is exercised here, the algorithm branches above.)
      assert :ok = perform_job(AssignWaiter, %{"order_id" => order.id, "org_id" => org.id})

      # With no Presence-alive candidates the order lands on the claim
      # board — unassigned, still placed, never lost.
      reloaded = Repo.get(Order, order.id)
      assert reloaded.status == :placed
      assert reloaded.waiter_membership_id == nil
      _ = solo
    end

    test "a vanished order is a safe no-op", %{org: org} do
      assert :ok =
               perform_job(AssignWaiter, %{
                 "order_id" => Ecto.UUID.generate(),
                 "org_id" => org.id
               })
    end
  end

  describe "accept_order/2" do
    test "the assigned waiter accepts; anyone else is rejected", %{scope: scope, item: item} do
      %{membership: assigned, scope: assigned_scope} = on_shift_waiter(scope)
      %{scope: other_scope} = on_shift_waiter(scope)

      order = placed_order(scope, item)
      {:ok, order} = Ordering.assign_waiter(scope, order, fn _, id -> id == assigned.id end)
      # Solo shortcut auto-accepted — build a fresh assigned-not-accepted
      # order by reassigning a new one manually instead.
      assert order.status == :accepted

      order2 = placed_order(scope, item)
      {:ok, order2} = Ordering.reassign_order(scope, order2, assigned.id)
      assert order2.status == :placed

      assert {:error, :not_yours} = Ordering.accept_order(other_scope, order2)
      assert {:ok, accepted} = Ordering.accept_order(assigned_scope, order2)
      assert accepted.status == :accepted
    end
  end

  describe "claim_order/2 — first tap wins (concurrency)" do
    test "two waiters hammering the same claim — exactly one wins", %{
      scope: scope,
      org: org,
      item: item
    } do
      %{scope: scope_a} = on_shift_waiter(scope)
      %{scope: scope_b} = on_shift_waiter(scope)

      order = placed_order(scope, item)
      # On the claim board: placed, unassigned.
      assert Repo.get(Order, order.id).waiter_membership_id == nil

      parent = self()

      results =
        [scope_a, scope_b]
        |> Task.async_stream(
          fn claimer_scope ->
            Sandbox.allow(Repo, parent, self())
            Repo.put_org_id(org.id)
            Ordering.claim_order(claimer_scope, order.id)
          end,
          max_concurrency: 2
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :already_claimed}, &1)) == 1

      claimed = Repo.get(Order, order.id)
      assert claimed.status == :accepted
      assert claimed.waiter_membership_id
    end
  end

  describe "Workers.EscalateUnacceptedOrder" do
    test "a still-unaccepted order escalates to the claim board", %{
      scope: scope,
      org: org,
      item: item
    } do
      %{membership: waiter} = on_shift_waiter(scope)
      order = placed_order(scope, item)
      {:ok, order} = Ordering.reassign_order(scope, order, waiter.id)
      assert order.status == :placed

      Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{scope.venue.id}:claim_board")

      assert :ok =
               perform_job(EscalateUnacceptedOrder, %{
                 "order_id" => order.id,
                 "org_id" => org.id,
                 "assigned_membership_id" => waiter.id
               })

      assert Repo.get(Order, order.id).waiter_membership_id == nil
      assert_received {:order_needs_claim, _}
    end

    test "an accepted order is left alone — jobs are delayed truth", %{
      scope: scope,
      org: org,
      item: item
    } do
      %{membership: waiter, scope: waiter_scope} = on_shift_waiter(scope)
      order = placed_order(scope, item)
      {:ok, order} = Ordering.reassign_order(scope, order, waiter.id)
      {:ok, _} = Ordering.accept_order(waiter_scope, order)

      assert :ok =
               perform_job(EscalateUnacceptedOrder, %{
                 "order_id" => order.id,
                 "org_id" => org.id,
                 "assigned_membership_id" => waiter.id
               })

      reloaded = Repo.get(Order, order.id)
      assert reloaded.status == :accepted
      assert reloaded.waiter_membership_id == waiter.id
    end

    test "a reassigned order is left alone (assigned membership no longer matches)", %{
      scope: scope,
      org: org,
      item: item
    } do
      %{membership: first} = on_shift_waiter(scope)
      %{membership: second} = on_shift_waiter(scope)
      order = placed_order(scope, item)
      {:ok, order} = Ordering.reassign_order(scope, order, first.id)
      {:ok, _} = Ordering.reassign_order(scope, order, second.id)

      assert :ok =
               perform_job(EscalateUnacceptedOrder, %{
                 "order_id" => order.id,
                 "org_id" => org.id,
                 "assigned_membership_id" => first.id
               })

      assert Repo.get(Order, order.id).waiter_membership_id == second.id
    end
  end

  describe "release_orders_to_claim_board/2 (Q44 / off-shift handoff)" do
    test "every open order on the waiter's plate goes to the claim board", %{
      scope: scope,
      item: item
    } do
      %{membership: waiter} = on_shift_waiter(scope)

      order_a = placed_order(scope, item)
      order_b = placed_order(scope, item)
      {:ok, _} = Ordering.reassign_order(scope, order_a, waiter.id)
      {:ok, _} = Ordering.reassign_order(scope, order_b, waiter.id)

      assert Ordering.release_orders_to_claim_board(scope, waiter.id) == 2
      assert Repo.get(Order, order_a.id).waiter_membership_id == nil
      assert Repo.get(Order, order_b.id).waiter_membership_id == nil
    end
  end

  describe "mark_unserveable/2 (Q9)" do
    test "flags the order without touching its status", %{scope: scope, item: item} do
      order = placed_order(scope, item)

      assert {:ok, flagged} = Ordering.mark_unserveable(scope, order)
      assert flagged.flag == :unserveable
      assert flagged.flagged_at
      assert flagged.status == order.status
    end
  end

  describe "call_waiter/2 (Q46)" do
    test "creates a waiter_calls row and notifies the assigned waiter", %{
      scope: scope,
      item: item
    } do
      %{membership: waiter} = on_shift_waiter(scope)
      table = table_fixture(scope)
      order = placed_order(scope, item, table_id: table.id)
      {:ok, order} = Ordering.reassign_order(scope, order, waiter.id)

      Phoenix.PubSub.subscribe(Tabletap.PubSub, "waiter:#{waiter.id}")

      assert {:ok, %WaiterCall{} = call} = Ordering.call_waiter(scope, order)
      assert call.table_id == table.id
      assert call.status == :open
      assert_received {:waiter_called, _order_id}
    end

    test "notifies the assigned waiter by push too (build-plan.md Feature 20)", %{
      scope: scope,
      org: org,
      item: item
    } do
      %{membership: waiter} = on_shift_waiter(scope)
      table = table_fixture(scope)
      order = placed_order(scope, item, table_id: table.id)
      {:ok, order} = Ordering.reassign_order(scope, order, waiter.id)

      assert {:ok, _call} = Ordering.call_waiter(scope, order)

      assert_enqueued(
        worker: Tabletap.Notifications.Workers.SendPush,
        args: %{
          "type" => "waiter",
          "org_id" => org.id,
          "membership_id" => waiter.id,
          "title" => "Table needs you",
          "body" => "Order ##{order.number}",
          "url" => "/waiter"
        }
      )
    end

    test "no push when the order has no assigned waiter yet — nothing specific to push to", %{
      scope: scope,
      item: item
    } do
      table = table_fixture(scope)
      order = placed_order(scope, item, table_id: table.id)

      assert {:ok, _call} = Ordering.call_waiter(scope, order)

      refute_enqueued(worker: Tabletap.Notifications.Workers.SendPush)
    end

    test "a pickup venue never creates a call (Q46)", %{scope: scope, venue: venue, item: item} do
      table = table_fixture(scope)
      order = placed_order(scope, item, table_id: table.id)

      {:ok, venue} = venue |> Ecto.Changeset.change(fulfillment_mode: :pickup) |> Repo.update()
      scope = %{scope | venue: venue}

      assert {:error, :pickup_venue} = Ordering.call_waiter(scope, order)
      assert Repo.aggregate(from(c in WaiterCall), :count) == 0
    end

    test "a takeaway order (no table) can't call a waiter", %{scope: scope, item: item} do
      order = placed_order(scope, item)
      assert {:error, :no_table} = Ordering.call_waiter(scope, order)
    end
  end
end

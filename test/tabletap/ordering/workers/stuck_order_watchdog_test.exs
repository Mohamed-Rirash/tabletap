defmodule Tabletap.Ordering.Workers.StuckOrderWatchdogTest do
  @moduledoc """
  build-plan.md Feature 21's stuck-order watchdog — reuses the exact
  "delayed" bar `Analytics.delayed?/2` already applies to the live
  dashboard tile (`Ordering.expected_prep_minutes/1`, defaulting to 10
  minutes when no item sets its own `prep_minutes`), just as a proactive
  push instead of a passive read.
  """
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Ecto.Query
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Ordering, Repo}
  alias Tabletap.Notifications.Workers.SendPush
  alias Tabletap.Ordering.{Cart, Order, OrderStateMachine}
  alias Tabletap.Ordering.Workers.StuckOrderWatchdog

  defp item_fixture(scope) do
    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    item
  end

  defp placed_order_aged(scope, item, minutes_ago) do
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    {:ok, order} = OrderStateMachine.transition(scope, order, :placed)

    placed_at =
      DateTime.utc_now() |> DateTime.add(-minutes_ago * 60, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(o in Order, where: o.id == ^order.id), set: [placed_at: placed_at])

    order
  end

  test "alerts managers/owners for an order past the expected-prep bar (default 10 min)" do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue, role: :owner}
    item = item_fixture(scope)

    stuck = placed_order_aged(scope, item, 15)

    assert :ok = perform_job(StuckOrderWatchdog, %{})

    assert_enqueued(
      worker: SendPush,
      args: %{
        "type" => "stuck_order",
        "order_id" => stuck.id,
        "org_id" => org.id,
        "venue_id" => venue.id
      }
    )
  end

  test "an order well within its expected prep time is left alone" do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue, role: :owner}
    item = item_fixture(scope)

    fresh = placed_order_aged(scope, item, 2)

    assert :ok = perform_job(StuckOrderWatchdog, %{})

    refute_enqueued(worker: SendPush, args: %{"order_id" => fresh.id})
  end

  test "a terminal-status order (e.g. served) is never alerted, however old" do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue, role: :owner}
    item = item_fixture(scope)

    order = placed_order_aged(scope, item, 120)

    Enum.each([:accepted, :preparing, :ready, :served], fn status ->
      {:ok, _} = OrderStateMachine.transition(scope, Repo.get!(Order, order.id), status)
    end)

    assert :ok = perform_job(StuckOrderWatchdog, %{})

    refute_enqueued(worker: SendPush, args: %{"order_id" => order.id})
  end

  test "a stuck order is only ever alerted once, across repeated ticks" do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue, role: :owner}
    item = item_fixture(scope)

    stuck = placed_order_aged(scope, item, 15)

    assert :ok = perform_job(StuckOrderWatchdog, %{})
    assert :ok = perform_job(StuckOrderWatchdog, %{})

    jobs =
      all_enqueued(worker: SendPush)
      |> Enum.filter(&(&1.args["order_id"] == stuck.id))

    assert length(jobs) == 1
  end

  test "sweeps every org independently, never crossing tenants" do
    %{org: org_a, venue: venue_a} = org_fixture()
    %{org: org_b, venue: venue_b} = org_fixture()

    Repo.put_org_id(org_a.id)
    scope_a = %Scope{org: org_a, venue: venue_a, role: :owner}
    item_a = item_fixture(scope_a)
    stuck_a = placed_order_aged(scope_a, item_a, 20)

    Repo.put_org_id(org_b.id)
    scope_b = %Scope{org: org_b, venue: venue_b, role: :owner}
    item_b = item_fixture(scope_b)
    stuck_b = placed_order_aged(scope_b, item_b, 20)

    assert :ok = perform_job(StuckOrderWatchdog, %{})

    assert_enqueued(
      worker: SendPush,
      args: %{"type" => "stuck_order", "order_id" => stuck_a.id, "org_id" => org_a.id}
    )

    assert_enqueued(
      worker: SendPush,
      args: %{"type" => "stuck_order", "order_id" => stuck_b.id, "org_id" => org_b.id}
    )
  end

  test "no orders anywhere is a no-op, not a crash" do
    %{} = org_fixture()
    assert :ok = perform_job(StuckOrderWatchdog, %{})
  end
end

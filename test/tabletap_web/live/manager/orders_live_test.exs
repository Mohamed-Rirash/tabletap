defmodule TabletapWeb.Manager.OrdersLiveTest do
  @moduledoc """
  `Manager.OrdersLive` had no test coverage at all before this (a
  pre-existing gap — build-plan.md Feature 22's tenant-isolation audit
  adds only the targeted cross-tenant check below, not a full
  backfill, same discipline `Waiter.QueueLive` got in Feature 20).
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering.{Order, OrderItem, OrderStateMachine}
  alias Tabletap.Repo

  setup :register_and_log_in_owner

  defp ready_order_fixture(scope, item) do
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
        subtotal: item.price,
        discount_total: Money.new!(item.price.currency, 0),
        total: item.price
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
        qty: 1,
        line_total: item.price
      })
      |> Repo.insert()

    Enum.reduce([:placed, :accepted, :preparing, :ready], order, fn status, acc ->
      {:ok, moved} = OrderStateMachine.transition(scope, acc, status)
      moved
    end)
  end

  test "an owner reaches the orders board", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/orders")
    assert html =~ "TableTap"
  end

  describe "cross-tenant isolation (build-plan.md Feature 22)" do
    test "manual_serve on another org's order id is a safe no-op, never a leak", %{conn: conn} do
      %{org: other_org, venue: other_venue} = org_fixture()
      Repo.put_org_id(other_org.id)
      other_scope = %Scope{org: other_org, venue: other_venue, role: :owner}

      {:ok, other_category} = Catalog.create_category(other_scope, %{"name" => "Mains"})

      {:ok, other_item} =
        Catalog.create_item(other_scope, other_category, %{
          "name" => "Burger",
          "price" => Money.new!(:USD, "5.00")
        })

      other_order = ready_order_fixture(other_scope, other_item)

      {:ok, lv, _html} = live(conn, ~p"/orders")
      render_click(lv, "manual_serve", %{"id" => other_order.id})

      assert Repo.get(Order, other_order.id, skip_org_id: true).status == :ready
    end
  end
end

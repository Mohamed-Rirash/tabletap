defmodule TabletapWeb.Cashier.PosLiveTest do
  @moduledoc """
  Build-plan.md Feature 15 — the register: ring up a walk-in item, take
  cash, comp (manager-gated), the Q3/Q26 verify+Revive lookup, and
  access gating (cashier/manager/owner admitted, waiter denied).
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
  alias Tabletap.Payments
  alias Tabletap.Repo

  setup :register_and_log_in_owner

  setup %{scope: scope} do
    Repo.put_org_id(scope.org.id)

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    {:ok, _shift} = Tabletap.Staffing.clock_in(scope)

    %{category: category, item: item}
  end

  describe "access" do
    test "an owner reaches the register (already clocked in via setup)", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/pos")
      assert html =~ "Point of sale"
    end

    test "a plain cashier reaches the register too", %{scope: scope} do
      %{user: user} = cashier_fixture(scope.org, scope.venue)
      conn = Phoenix.ConnTest.build_conn() |> log_in_user(user)

      {:ok, _view, html} = live(conn, ~p"/pos")
      assert html =~ "Point of sale"
    end

    test "a waiter is denied", %{scope: scope} do
      %{user: user} = waiter_fixture(scope.org, scope.venue)
      conn = Phoenix.ConnTest.build_conn() |> log_in_user(user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/pos")
    end

    test "off shift shows a clock-in prompt, not the register", %{conn: conn, scope: scope} do
      {:ok, _shift} = Tabletap.Staffing.clock_out(scope)

      {:ok, _view, html} = live(conn, ~p"/pos")
      assert html =~ "You&#39;re off shift"
      refute html =~ "Point of sale — empty"
    end
  end

  describe "ringing up a walk-in ticket" do
    test "tapping a no-modifier item adds it straight to the ticket (ui-rules.md: no sheet), and Charge fires the order as cash",
         %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, ~p"/pos")

      view |> element("button[phx-click=open_item][phx-value-id='#{item.id}']") |> render_click()
      refute has_element?(view, "h3", "Latte")
      assert has_element?(view, "p", "Latte")

      view |> element("button", "Charge") |> render_click()
      assert has_element?(view, "h3", "Order #")

      view |> element("button", "Cash") |> render_click()
      view |> element("#pos-tender-form") |> render_change(%{"tendered" => "5.00"})
      view |> element("button", "Confirm cash payment") |> render_click()

      assert has_element?(view, "p", "Paid — fired to the kitchen.")
    end

    test "an item with modifier groups still opens the quick-sheet", %{
      conn: conn,
      scope: scope,
      category: category
    } do
      {:ok, group} = Catalog.create_modifier_group(scope, %{"name" => "Milk"})

      {:ok, _option} =
        Catalog.create_modifier_option(scope, group, %{
          "name" => "Oat milk",
          "price_delta" => Money.new!(:USD, "0.50")
        })

      {:ok, mocha} =
        Catalog.create_item(scope, category, %{
          "name" => "Mocha",
          "price" => Money.new!(:USD, "4.00")
        })

      {:ok, _} = Catalog.attach_group_to_item(scope, mocha, group)

      {:ok, view, _html} = live(conn, ~p"/pos")

      view |> element("button[phx-click=open_item][phx-value-id='#{mocha.id}']") |> render_click()
      assert has_element?(view, "h3", "Mocha")
      assert has_element?(view, "label", "Oat milk")

      view |> element("button", "Add to ticket") |> render_click()
      assert has_element?(view, "p", "Mocha")
    end

    test "removing every line disables Charge again", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, ~p"/pos")

      view |> element("button[phx-click=open_item][phx-value-id='#{item.id}']") |> render_click()

      view |> element("button[phx-click=remove_line]") |> render_click()
      refute has_element?(view, "button", "Charge")
    end
  end

  describe "dine-in requires a table" do
    test "Charge is disabled until a table is picked", %{conn: conn, scope: scope, item: item} do
      table = table_fixture(scope, %{"number" => "7"})
      {:ok, view, _html} = live(conn, ~p"/pos")

      view |> element("button[phx-click=set_kind][phx-value-kind=dine_in]") |> render_click()
      view |> element("button[phx-click=open_item][phx-value-id='#{item.id}']") |> render_click()

      assert view |> element("button", "Charge") |> render() =~ "disabled"

      view |> element("select[name=table_id]") |> render_change(%{"table_id" => table.id})
      refute view |> element("button", "Charge") |> render() =~ "disabled"
    end
  end

  describe "discounts and comp" do
    test "a discount reduces the total on the payment screen", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, ~p"/pos")

      view |> element("button[phx-click=open_item][phx-value-id='#{item.id}']") |> render_click()
      view |> element("button", "Charge") |> render_click()

      view
      |> form("form[phx-submit=apply_discount]",
        discount: %{"amount" => "1.00", "reason" => "Regular"}
      )
      |> render_submit()

      assert has_element?(view, "span", "Regular")
    end

    test "owner can comp — total zeroes and the order fires", %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, ~p"/pos")

      view |> element("button[phx-click=open_item][phx-value-id='#{item.id}']") |> render_click()
      view |> element("button", "Charge") |> render_click()

      view
      |> form("form[phx-submit=pay_comp]", comp: %{"reason" => "Owner's friend"})
      |> render_submit()

      assert has_element?(view, "p", "Paid — fired to the kitchen.")
    end

    test "a plain cashier gets no comp form at all", %{scope: scope, item: item} do
      %{user: user, membership: cashier} = cashier_fixture(scope.org, scope.venue)
      conn = Phoenix.ConnTest.build_conn() |> log_in_user(user)

      cashier_scope = %Scope{
        org: scope.org,
        venue: scope.venue,
        role: :cashier,
        membership: cashier
      }

      {:ok, _shift} = Tabletap.Staffing.clock_in(cashier_scope)

      {:ok, view, _html} = live(conn, ~p"/pos")

      view |> element("button[phx-click=open_item][phx-value-id='#{item.id}']") |> render_click()
      view |> element("button", "Charge") |> render_click()

      refute has_element?(view, "form[phx-submit=pay_comp]")
    end
  end

  describe "verify + Revive (Q3/Q26)" do
    test "verifies a customer's own pay-at-counter order and fires it", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      guest_scope = %Scope{org: scope.org, venue: scope.venue, role: :guest}
      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(guest_scope, token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(guest_scope, cart)
      {:ok, _payment} = Payments.record_cash_intent(guest_scope, order)

      {:ok, view, _html} = live(conn, ~p"/pos")

      view |> element("button", "Verify cash order") |> render_click()

      view
      |> element("form[phx-submit=lookup_order]")
      |> render_submit(%{"number" => to_string(order.number)})

      assert has_element?(view, "p", "Order ##{order.number}")

      view |> element("button", "Verify paid") |> render_click()

      order = Ordering.get_order(scope, order.id)
      assert order.status == :placed
    end

    test "Revive brings back an expired cash order", %{conn: conn, scope: scope, item: item} do
      guest_scope = %Scope{org: scope.org, venue: scope.venue, role: :guest}
      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(guest_scope, token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(guest_scope, cart)
      {:ok, _payment} = Payments.record_cash_intent(guest_scope, order)
      {:ok, order} = OrderStateMachine.transition(guest_scope, order, :expired)

      {:ok, view, _html} = live(conn, ~p"/pos")

      view |> element("button", "Verify cash order") |> render_click()

      view
      |> element("form[phx-submit=lookup_order]")
      |> render_submit(%{"number" => to_string(order.number)})

      assert has_element?(view, "button", "Revive & verify paid")

      view |> element("button", "Revive & verify paid") |> render_click()

      order = Ordering.get_order(scope, order.id)
      assert order.status == :placed
    end
  end

  describe "cash refunds" do
    test "refunds a settled cash order and nets it from expected cash", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      order = pending_order_from_pos(scope, item)
      {:ok, _payment} = Payments.settle_cash_now(scope, order, scope.membership)

      {:ok, view, _html} = live(conn, ~p"/pos")

      view |> element("button", "Refund") |> render_click()

      view
      |> element("#pos-refund-lookup-form")
      |> render_submit(%{"number" => to_string(order.number)})

      assert has_element?(view, "p", "Order ##{order.number}")

      view
      |> form("#pos-refund-form", %{"amount" => "3.50", "reason" => "Wrong drink"})
      |> render_submit()

      assert render(view) =~ "Refunded order ##{order.number}."

      payment = Payments.get_latest_payment_for_order(scope, order.id)
      [refund] = Repo.preload(payment, :refunds).refunds
      assert refund.reason == "Wrong drink"
      assert refund.status == :succeeded

      preview = Payments.z_report_preview(scope, Tabletap.Tenants.business_date(scope.venue))

      assert Money.equal?(
               Map.get(preview.cash_counts, scope.membership.id, Money.new!(:USD, 0)),
               Money.new!(:USD, 0)
             )
    end

    test "an order that was never paid shows nothing to refund", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      order = pending_order_from_pos(scope, item)

      {:ok, view, _html} = live(conn, ~p"/pos")

      view |> element("button", "Refund") |> render_click()

      view
      |> element("#pos-refund-lookup-form")
      |> render_submit(%{"number" => to_string(order.number)})

      assert render(view) =~ "has no payment to refund"
      refute has_element?(view, "#pos-refund-form")
    end

    defp pending_order_from_pos(scope, item) do
      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(scope, cart)
      order
    end
  end

  describe "cross-tenant isolation (build-plan.md Feature 22)" do
    test "order-number lookup never crosses tenants, even on a colliding number", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      # Order numbers are sequential *per venue* (build-plan.md Feature
      # 08) — two fresh venues both starting at #1 is the realistic
      # worst case for this lookup, not a contrived one. Priced very
      # differently on purpose: if the lookup ever leaked the other
      # tenant's order, its total ($99.00) would give it away —
      # whereas the correct behavior (each org's #1 resolves to *its
      # own* #1) is indistinguishable from "not found" on total alone.
      %{org: other_org, venue: other_venue} = org_fixture()
      Repo.put_org_id(other_org.id)
      other_scope = %Scope{org: other_org, venue: other_venue, role: :owner}

      {:ok, other_category} = Catalog.create_category(other_scope, %{"name" => "Drinks"})

      {:ok, other_item} =
        Catalog.create_item(other_scope, other_category, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "99.00")
        })

      other_order = pending_order_from_pos(other_scope, other_item)

      # Same setup as every other test in this file — a fresh order at
      # *this* org's venue, likely with the exact same #1.
      Repo.put_org_id(scope.org.id)
      mine = pending_order_from_pos(scope, item)
      assert mine.number == other_order.number

      {:ok, view, _html} = live(conn, ~p"/pos")
      view |> element("button", "Verify cash order") |> render_click()

      html =
        view
        |> element("#pos-lookup-form")
        |> render_submit(%{"number" => to_string(other_order.number)})

      # A lookup by number legitimately finds *this org's own* order at
      # that number (colliding numbers across tenants is expected, not
      # a bug) — the leak to rule out is showing the other tenant's
      # $99.00 order instead of this org's own $3.50 one.
      assert html =~ "3.50"
      refute html =~ "99.00"
    end
  end
end

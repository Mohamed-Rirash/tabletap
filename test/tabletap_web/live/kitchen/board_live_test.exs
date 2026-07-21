defmodule TabletapWeb.Kitchen.BoardLiveTest do
  @moduledoc """
  Build-plan.md Feature 14 — the KDS board: tickets land in the right
  columns, modifiers/notes render in full (Q12's invariant), the footer
  advance and header undo move tickets live via the stream update path,
  86'd tickets carry their badge (Q27), and the route admits kitchen
  staff + managers but nobody else.
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering.{Order, OrderItem, OrderItemModifier, OrderStateMachine}
  alias Tabletap.Repo
  alias Tabletap.Tenants.Membership

  setup :register_and_log_in_owner

  setup %{scope: scope} do
    Repo.put_org_id(scope.org.id)

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Mains"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Burger",
        "price" => Money.new!(:USD, "5.00"),
        "prep_minutes" => 12
      })

    %{item: item}
  end

  defp order_fixture(scope, status, item, attrs \\ %{}) do
    {item_notes, attrs} = Map.pop(attrs, :item_notes)
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
      |> Map.merge(attrs)
      |> Order.new_changeset()
      |> Repo.insert()

    {:ok, order_item} =
      %OrderItem{}
      |> Ecto.Changeset.change(%{
        org_id: scope.org.id,
        order_id: order.id,
        menu_item_id: item.id,
        name_snapshot: item.name,
        unit_price_snapshot: item.price,
        qty: 1,
        line_total: item.price,
        notes: item_notes
      })
      |> Repo.insert()

    order = Repo.preload(order, :items)

    [:placed, :accepted, :preparing, :ready]
    |> Enum.take_while(&(&1 != status))
    |> Kernel.++([status])
    |> Enum.reduce({order, order_item}, fn to, {acc, oi} ->
      {:ok, moved} = OrderStateMachine.transition(scope, acc, to)
      {moved, oi}
    end)
  end

  describe "board rendering" do
    test "tickets land in their columns with modifiers and notes in full", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      {placed, placed_item} =
        order_fixture(scope, :placed, item, %{item_notes: "nut allergy — please confirm"})

      {preparing, _} = order_fixture(scope, :preparing, item)
      {ready, _} = order_fixture(scope, :ready, item)

      {:ok, group} = Catalog.create_modifier_group(scope, %{"name" => "Remove"})

      {:ok, option} =
        Catalog.create_modifier_option(scope, group, %{
          "name" => "No onions",
          "price_delta" => Money.new!(:USD, 0)
        })

      {:ok, _} =
        %OrderItemModifier{}
        |> Ecto.Changeset.change(%{
          org_id: scope.org.id,
          order_item_id: placed_item.id,
          option_id: option.id,
          name_snapshot: "No onions",
          price_delta_snapshot: Money.new!(:USD, 0)
        })
        |> Repo.insert()

      {:ok, view, html} = live(conn, ~p"/kitchen")

      assert has_element?(view, "#new_orders-#{placed.id}")
      assert has_element?(view, "#preparing_orders-#{preparing.id}")
      assert has_element?(view, "#ready_orders-#{ready.id}")

      # Q12's invariant — the modifier line and the allergy note render
      # complete, never truncated behind a tap.
      assert html =~ "No onions"
      assert html =~ "nut allergy — please confirm"
    end

    test "an 86'd-item ticket carries its warning badge (Q27)", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      {order, _} = order_fixture(scope, :preparing, item)
      {:ok, _} = order |> Order.flag_changeset(:contains_86d_item) |> Repo.update()

      {:ok, _view, html} = live(conn, ~p"/kitchen")

      assert html =~ "contains 86&#39;d item"
    end
  end

  describe "advancing tickets" do
    test "Start moves a placed ticket to Preparing (through accepted)", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      {order, _} = order_fixture(scope, :placed, item)

      {:ok, view, _html} = live(conn, ~p"/kitchen")

      view
      |> element("#new_orders-#{order.id} button", "Start")
      |> render_click()

      assert has_element?(view, "#preparing_orders-#{order.id}")
      refute has_element?(view, "#new_orders-#{order.id}")
    end

    test "Ready moves a preparing ticket, undo brings it back (Q25)", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      {order, _} = order_fixture(scope, :preparing, item)

      {:ok, view, _html} = live(conn, ~p"/kitchen")

      view
      |> element("#preparing_orders-#{order.id} button", "Ready")
      |> render_click()

      assert has_element?(view, "#ready_orders-#{order.id}")

      view
      |> element("#ready_orders-#{order.id} [phx-click=undo]")
      |> render_click()

      assert has_element?(view, "#preparing_orders-#{order.id}")
      refute has_element?(view, "#ready_orders-#{order.id}")
    end

    test "a stale tap refreshes the board instead of crashing", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      {order, _} = order_fixture(scope, :placed, item)

      {:ok, view, _html} = live(conn, ~p"/kitchen")

      # Another device wins the race: the order moves on out-of-band.
      {:ok, _} = order |> then(&Tabletap.Ordering.kitchen_start_order(scope, &1))

      # This tablet's tap arrives with the stale ticket id — Start is no
      # longer legal, the board flashes and reloads.
      render_click(view, "start", %{"id" => order.id})

      assert render(view) =~ "That ticket moved on"
      assert has_element?(view, "#preparing_orders-#{order.id}")
    end
  end

  describe "live updates from elsewhere" do
    test "a new order appears without refresh, a served one leaves", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      {ready, _} = order_fixture(scope, :ready, item)

      {:ok, view, _html} = live(conn, ~p"/kitchen")
      assert has_element?(view, "#ready_orders-#{ready.id}")

      {placed, _} = order_fixture(scope, :placed, item)
      assert has_element?(view, "#new_orders-#{placed.id}")

      {:ok, _} = OrderStateMachine.transition(scope, Repo.preload(ready, :items), :served)
      refute has_element?(view, "#ready_orders-#{ready.id}")
    end
  end

  describe "access" do
    test "a kitchen-role user gets the board", %{scope: scope, item: item} do
      {_order, _} = order_fixture(scope, :placed, item)

      user = Tabletap.AccountsFixtures.user_fixture()

      {:ok, _membership} =
        %Membership{}
        |> Membership.changeset(%{
          org_id: scope.org.id,
          venue_id: scope.venue.id,
          user_id: user.id,
          role: :kitchen
        })
        |> Repo.insert()

      conn = Phoenix.ConnTest.build_conn() |> log_in_user(user)

      {:ok, _view, html} = live(conn, ~p"/kitchen")
      assert html =~ "Kitchen"
    end

    test "a waiter is denied", %{scope: scope} do
      %{user: user} = waiter_fixture(scope.org, scope.venue)
      conn = Phoenix.ConnTest.build_conn() |> log_in_user(user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/kitchen")
    end

    test "kitchen logins land on /kitchen", %{} do
      user = Tabletap.AccountsFixtures.user_fixture()
      %{org: org, venue: venue} = org_fixture()

      {:ok, _membership} =
        %Membership{}
        |> Membership.changeset(%{
          org_id: org.id,
          venue_id: venue.id,
          user_id: user.id,
          role: :kitchen
        })
        |> Repo.insert()

      scope = %Scope{user: user, org: org, venue: venue, role: :kitchen}

      assert TabletapWeb.UserAuth.signed_in_path(%{assigns: %{current_scope: scope}}) ==
               "/kitchen"
    end
  end

  describe "cross-tenant isolation (build-plan.md Feature 22)" do
    test "start/mark_ready/undo on another org's order id are all safe no-ops", %{conn: conn} do
      %{org: other_org, venue: other_venue} = org_fixture()
      Repo.put_org_id(other_org.id)
      other_scope = %Scope{org: other_org, venue: other_venue, role: :owner}

      {:ok, other_category} = Catalog.create_category(other_scope, %{"name" => "Mains"})

      {:ok, other_item} =
        Catalog.create_item(other_scope, other_category, %{
          "name" => "Burger",
          "price" => Money.new!(:USD, "5.00"),
          "prep_minutes" => 12
        })

      {other_order, _} = order_fixture(other_scope, :placed, other_item)

      {:ok, lv, _html} = live(conn, ~p"/kitchen")

      render_click(lv, "start", %{"id" => other_order.id})
      render_click(lv, "mark_ready", %{"id" => other_order.id})
      render_click(lv, "undo", %{"id" => other_order.id})

      assert Repo.get(Order, other_order.id, skip_org_id: true).status == :placed
    end
  end
end

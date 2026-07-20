defmodule TabletapWeb.Manager.Analytics.ReportsLiveTest do
  @moduledoc """
  `TabletapWeb.Manager.Analytics.ReportsLive` at `/reports`
  (build-plan.md Feature 18, owner-dashboard.md's Report Center).
  Since every report type renders through a different clause of the
  same `report_body/1` component, this exercises each of the 13 types
  at least once to prove none of them crash on real (or empty) data —
  the numbers themselves are already reconciled in
  `test/tabletap/analytics/reports_test.exs`.
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Analytics.Reports
  alias Tabletap.{Catalog, Ordering, Payments, Repo}
  alias Tabletap.Ordering.{Cart, OrderStateMachine}

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/reports")
    end

    test "redirects an owner off-trial on Essentials — the Report Center is Growth+", %{
      conn: conn
    } do
      %{org: org, user: user} = org_fixture()

      org
      |> Ecto.Changeset.change(plan: :essentials, subscription_status: :active)
      |> Repo.update!()

      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/dashboard", flash: flash}}} = live(conn, ~p"/reports")
      assert flash["error"] =~ "Growth"
    end

    test "an active Growth-plan owner passes the gate", %{conn: conn} do
      %{org: org, user: user} = org_fixture()

      org
      |> Ecto.Changeset.change(plan: :growth, subscription_status: :active)
      |> Repo.update!()

      conn = log_in_user(conn, user)

      assert {:ok, _lv, html} = live(conn, ~p"/reports")
      assert html =~ "Report Center"
    end
  end

  describe "as an owner" do
    setup :register_and_log_in_owner

    setup %{org: org, venue: venue} do
      Repo.put_org_id(org.id)
      scope = %Scope{org: org, venue: venue}

      {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

      {:ok, item} =
        Catalog.create_item(scope, category, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "3.50")
        })

      %{scope: scope, item: item}
    end

    test "defaults to the revenue report over the last 7 days", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/reports")

      assert html =~ "Report Center"
      assert html =~ "Discounts"
    end

    test "every report type renders without crashing, empty or with real data", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(cashier_scope, token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(cashier_scope, cart)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)

      Enum.reduce(
        [:accepted, :preparing, :ready, :served],
        Ordering.get_order(scope, order.id),
        fn status, acc ->
          {:ok, moved} = OrderStateMachine.transition(scope, acc, status)
          moved
        end
      )

      for type <- Reports.report_types() do
        {:ok, _lv, html} = live(conn, ~p"/reports?#{[report: type, period: "today"]}")
        assert html =~ "Report Center", "report #{type} failed to render"
      end
    end

    test "switching report type patches the URL and re-renders that report's table", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/reports")

      html =
        lv |> form(~s(form[phx-change="pick_report"]), %{"report" => "orders"}) |> render_change()

      assert html =~ "No orders in this period."
    end

    test "a custom period submits and patches to the given dates", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/reports")

      lv
      |> form("form[phx-submit=\"set_custom_period\"]", %{
        "from" => "2026-01-01",
        "to" => "2026-01-05"
      })
      |> render_submit()

      html = render(lv)
      assert html =~ "2026-01-01"
      assert html =~ "2026-01-05"
    end

    test "CSV export link points at the current report and date range", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/reports?report=orders&period=30d")
      assert html =~ "/reports.csv?"
      assert html =~ "report=orders"
    end

    test "subscribing to a report adds it to the list, and can be unsubscribed", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/reports?report=revenue")
      refute html =~ "Revenue · Daily"

      html =
        lv
        |> form(~s(form[phx-submit="subscribe"]), %{"frequency" => "daily"})
        |> render_submit()

      assert html =~ "Revenue · Daily"

      html = lv |> element(~s(button[phx-click="unsubscribe"])) |> render_click()
      refute html =~ "Revenue · Daily"
    end

    test "subscribing twice at the same frequency is rejected", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/reports?report=revenue")

      lv |> form(~s(form[phx-submit="subscribe"]), %{"frequency" => "daily"}) |> render_submit()

      html =
        lv |> form(~s(form[phx-submit="subscribe"]), %{"frequency" => "daily"}) |> render_submit()

      assert html =~ "already subscribed"
    end
  end
end

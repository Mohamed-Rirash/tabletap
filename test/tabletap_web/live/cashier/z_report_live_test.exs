defmodule TabletapWeb.Cashier.ZReportLiveTest do
  @moduledoc """
  Build-plan.md Feature 15's end-of-day close: a live preview before
  closing, `close_z_report/3` freezes it, and a closed day renders the
  stored snapshot on a later visit (design-qa.md Q38). The "can't close
  twice" guard itself is exercised at the context level
  (`test/tabletap/payments/pos_test.exs`) — this file only checks the
  LiveView reflects that a closed day, not the guard mechanics.
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Cart
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

    %{user: user, membership: cashier} = cashier_fixture(scope.org, scope.venue)

    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    {:ok, _payment} = Payments.settle_cash_now(scope, order, cashier)

    %{item: item, cashier: cashier, cashier_user: user}
  end

  test "shows the live preview with an expected-cash row per cashier", %{
    conn: conn,
    cashier_user: cashier_user
  } do
    {:ok, _view, html} = live(conn, ~p"/pos/z-report")

    assert html =~ "Cash reconciliation — enter what&#39;s actually in the drawer"
    assert html =~ cashier_user.email
    assert html =~ "Expected"
  end

  test "closing persists the snapshot and shows it read-only on a later visit", %{
    conn: conn,
    cashier: cashier
  } do
    {:ok, view, _html} = live(conn, ~p"/pos/z-report")

    view
    |> form("#close-report-form", %{"counted" => %{cashier.id => "3.50"}})
    |> render_submit()

    assert has_element?(view, "span", "Closed")

    {:ok, _view2, html2} = live(conn, ~p"/pos/z-report")
    assert html2 =~ "Closed"
    refute html2 =~ "Close business day"
  end
end

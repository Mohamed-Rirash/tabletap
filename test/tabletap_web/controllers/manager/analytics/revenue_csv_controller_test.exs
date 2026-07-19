defmodule TabletapWeb.Manager.Analytics.RevenueCsvControllerTest do
  @moduledoc """
  `Manager.Analytics.RevenueCsvController` — the Revenue & Sales screen's
  CSV export (build-plan.md Feature 18).
  """
  use TabletapWeb.ConnCase, async: true

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Cart
  alias Tabletap.Payments
  alias Tabletap.Repo

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

  test "returns a CSV attachment reconciling a real sale", %{conn: conn, scope: scope, item: item} do
    %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
    cashier_scope = %{scope | role: :cashier, membership: cashier}
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(cashier_scope, token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(cashier_scope, cart)
    {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)

    today = Tabletap.Tenants.business_date(scope.venue)

    conn =
      get(
        conn,
        ~p"/analytics/revenue.csv?#{[from: Date.to_string(today), to: Date.to_string(today)]}"
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/csv"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "attachment"

    body = response(conn, 200)
    assert body =~ "Date,Orders,Gross sales"
    assert body =~ "1,3.50"
  end
end

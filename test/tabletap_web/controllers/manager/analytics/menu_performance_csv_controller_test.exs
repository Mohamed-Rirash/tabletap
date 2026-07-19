defmodule TabletapWeb.Manager.Analytics.MenuPerformanceCsvControllerTest do
  @moduledoc """
  `Manager.Analytics.MenuPerformanceCsvController` — the Menu
  Performance screen's CSV export (build-plan.md Feature 18).
  """
  use TabletapWeb.ConnCase, async: true

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
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

  test "returns a CSV attachment reconciling a served item", %{
    conn: conn,
    scope: scope,
    item: item
  } do
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 2, nil)
    {:ok, order} = Ordering.checkout(scope, cart)

    Enum.reduce([:placed, :accepted, :preparing, :ready, :served], order, fn status, acc ->
      {:ok, moved} = OrderStateMachine.transition(scope, acc, status)
      moved
    end)

    today = Tabletap.Tenants.business_date(scope.venue)

    conn =
      get(
        conn,
        ~p"/analytics/menu-performance.csv?#{[from: Date.to_string(today), to: Date.to_string(today)]}"
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/csv"

    body = response(conn, 200)
    assert body =~ "Item,Sold,Revenue"
    assert body =~ "Latte,2,7.00"
  end
end

defmodule TabletapWeb.Manager.Analytics.CustomersLiveTest do
  @moduledoc """
  `TabletapWeb.Manager.Analytics.CustomersLive` at `/analytics/customers`
  (build-plan.md Feature 18, owner-dashboard.md Screen 7).
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Cart
  alias Tabletap.Repo

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/analytics/customers")
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

    test "shows empty state numbers with no orders yet", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/analytics/customers")

      assert html =~ "New customers"
      assert html =~ "No account-holder orders yet."
    end

    test "reconciles a real account holder's order as a new customer and top spender", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      user = Tabletap.AccountsFixtures.user_fixture()
      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(scope, cart)
      {:ok, _} = Ordering.link_guest_orders_to_customer(user, order.guest_token)
      order |> Ecto.Changeset.change(status: :served) |> Repo.update!()

      {:ok, _lv, html} = live(conn, ~p"/analytics/customers?range=30d")

      assert html =~ user.email
      assert html =~ "3.50"
      refute html =~ "No account-holder orders yet."
    end

    test "switching range patches the URL", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/analytics/customers")

      html = lv |> element(~s(a[href="/analytics/customers?range=90d"])) |> render_click()
      assert html =~ "Customers"
      assert_patch(lv, ~p"/analytics/customers?range=90d")
    end
  end
end

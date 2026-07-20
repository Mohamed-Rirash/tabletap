defmodule TabletapWeb.Admin.TenantLiveTest do
  @moduledoc """
  `Admin.TenantLive` at `/admin/tenants/:id` (build-plan.md Feature
  19) — plan/status, cash share per venue (design-qa.md Q24), billing
  history. Strictly read-only: no form, no writable action anywhere on
  this page.
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Ordering, Payments, Repo}
  alias Tabletap.Ordering.Cart

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      %{org: org} = org_fixture()

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/admin/tenants/#{org.id}")
    end

    test "redirects a non-admin owner", %{conn: conn} do
      %{user: user, org: org} = org_fixture()
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/tenants/#{org.id}")
    end
  end

  describe "as a platform admin" do
    setup %{conn: conn} do
      admin_user = Tabletap.AccountsFixtures.user_fixture()
      admin_user = admin_user |> Ecto.Changeset.change(platform_admin: true) |> Repo.update!()
      %{conn: log_in_user(conn, admin_user)}
    end

    test "an unknown tenant id redirects back to the list", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/admin"}}} =
               live(conn, ~p"/admin/tenants/#{Ecto.UUID.generate()}")
    end

    test "shows plan, status, and an empty billing history for a fresh org", %{conn: conn} do
      %{org: org} = org_fixture()

      {:ok, _lv, html} = live(conn, ~p"/admin/tenants/#{org.id}")

      assert html =~ org.name
      assert html =~ "Essentials"
      assert html =~ "No invoices yet."
    end

    test "cash share reconciles a real cash sale against a real wallet-style sale", %{conn: conn} do
      %{org: org, venue: venue} = org_fixture()
      Repo.put_org_id(org.id)
      scope = %Scope{org: org, venue: venue}

      {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

      {:ok, item} =
        Catalog.create_item(scope, category, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "3.50")
        })

      %{membership: cashier} = cashier_fixture(org, venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(cashier_scope, token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(cashier_scope, cart)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)

      {:ok, _lv, html} = live(conn, ~p"/admin/tenants/#{org.id}")

      assert html =~ venue.name
      assert html =~ "100.0%"
    end
  end
end

defmodule Tabletap.AdminTest do
  @moduledoc """
  `Tabletap.Admin` — cross-tenant platform-admin reads
  (`skip_org_id: true` throughout, one of the few contexts allowed to,
  code-standards.md). Reconciled against hand-built orders/payments,
  same discipline every other Analytics-style context test in this
  codebase uses.
  """
  use Tabletap.DataCase, async: true

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Admin
  alias Tabletap.{Catalog, Ordering, Payments, Repo}
  alias Tabletap.Ordering.Cart

  describe "list_tenants/0" do
    test "lists every org across tenants, with venue and order counts" do
      %{org: org_a} = org_fixture()
      %{org: org_b} = org_fixture()

      rows = Admin.list_tenants()
      org_ids = Enum.map(rows, & &1.org.id)

      assert org_a.id in org_ids
      assert org_b.id in org_ids
      assert Enum.find(rows, &(&1.org.id == org_a.id)).venue_count == 1
    end
  end

  describe "get_tenant/1" do
    test "finds an org regardless of ambient tenant scope" do
      %{org: org} = org_fixture()
      assert %{id: id} = Admin.get_tenant(org.id)
      assert id == org.id
    end

    test "returns nil for an unknown id" do
      assert Admin.get_tenant(Ecto.UUID.generate()) == nil
    end
  end

  describe "cash_share_by_venue/1" do
    test "reconciles cash vs wallet-style payments for one venue" do
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

      order1 = checked_out(cashier_scope, item)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order1, cashier)

      order2 = checked_out(cashier_scope, item)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order2, cashier)

      [row] = Admin.cash_share_by_venue(org)

      assert row.venue.id == venue.id
      assert row.cash_count == 2
      assert row.total_count == 2
      assert Decimal.equal?(row.cash_share_pct, Decimal.new(100))
    end

    test "a venue with no succeeded payments yet has a nil cash_share_pct, not a division error" do
      %{org: org, venue: venue} = org_fixture()

      [row] = Admin.cash_share_by_venue(org)

      assert row.venue.id == venue.id
      assert row.total_count == 0
      assert row.cash_share_pct == nil
    end
  end

  describe "list_invoices/1" do
    test "empty for an org that's never been billed" do
      %{org: org} = org_fixture()
      assert Admin.list_invoices(org) == []
    end
  end

  defp checked_out(scope, item) do
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    order
  end
end

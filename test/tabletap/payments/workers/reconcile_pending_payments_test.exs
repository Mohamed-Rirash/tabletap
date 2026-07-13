defmodule Tabletap.Payments.Workers.ReconcilePendingPaymentsTest do
  @moduledoc """
  Same cross-tenant sweep pattern as `Ordering.Workers.SweepExpiredHoldsTest`
  — loops every org, resolving each org's own pending payments via a
  mocked `lookup/2` (code-standards.md: no test hits a real provider API).
  """
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Mox
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Cart
  alias Tabletap.Payments
  alias Tabletap.Payments.{Payment, ProviderMock}
  alias Tabletap.Payments.Workers.ReconcilePendingPayments
  alias Tabletap.Repo

  setup :verify_on_exit!

  defp pending_payment_fixture(scope) do
    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    {:ok, payment} = Payments.charge_order(scope, order, "252611111111")
    payment
  end

  test "resolves an APPROVED lookup, across every org, in one pass" do
    %{org: org_a, venue: venue_a} = org_fixture()
    venue_a = charges_enabled_venue_fixture(venue_a)
    Repo.put_org_id(org_a.id)
    scope_a = %Scope{org: org_a, venue: venue_a}
    payment_a = pending_payment_fixture(scope_a)

    %{org: org_b, venue: venue_b} = org_fixture()
    venue_b = charges_enabled_venue_fixture(venue_b)
    Repo.put_org_id(org_b.id)
    scope_b = %Scope{org: org_b, venue: venue_b}
    payment_b = pending_payment_fixture(scope_b)

    expect(ProviderMock, :lookup, fn _creds, _ref ->
      {:ok, %{provider_txn_id: "txn-a", state: :approved}}
    end)

    expect(ProviderMock, :lookup, fn _creds, _ref ->
      {:ok, %{provider_txn_id: "txn-b", state: :approved}}
    end)

    assert :ok = perform_job(ReconcilePendingPayments, %{})

    Repo.put_org_id(org_a.id)
    assert Repo.get(Payment, payment_a.id).status == :succeeded

    Repo.put_org_id(org_b.id)
    assert Repo.get(Payment, payment_b.id).status == :succeeded
  end

  test "a still-pending lookup leaves the payment untouched for the next pass" do
    %{org: org, venue: venue} = org_fixture()
    venue = charges_enabled_venue_fixture(venue)
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue}
    payment = pending_payment_fixture(scope)

    expect(ProviderMock, :lookup, fn _creds, _ref ->
      {:ok, %{provider_txn_id: nil, state: :pending}}
    end)

    assert :ok = perform_job(ReconcilePendingPayments, %{})
    assert Repo.get(Payment, payment.id).status == :pending
  end

  test "no pending payments anywhere is a no-op, not a crash" do
    %{} = org_fixture()
    assert :ok = perform_job(ReconcilePendingPayments, %{})
  end
end

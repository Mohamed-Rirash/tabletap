defmodule Tabletap.Payments.Workers.ChargeOrderTest do
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
  alias Tabletap.Payments.Workers.ChargeOrder
  alias Tabletap.Repo

  setup :verify_on_exit!

  setup do
    %{org: org, venue: venue} = org_fixture()
    venue = charges_enabled_venue_fixture(venue)
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue}

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

    %{scope: scope, org: org, payment: payment}
  end

  test "an APPROVED charge result places the order", %{org: org, payment: payment} do
    expect(ProviderMock, :charge, fn _creds, _request ->
      {:ok, %{provider_txn_id: "waafi-1", state: :approved}}
    end)

    assert :ok =
             perform_job(ChargeOrder, %{
               "payment_id" => payment.id,
               "org_id" => org.id,
               "wallet_msisdn" => "252611111111"
             })

    assert Repo.get(Payment, payment.id).status == :succeeded
  end

  test "a definitive decline cancels the order instead of leaving it pending", %{
    org: org,
    payment: payment
  } do
    expect(ProviderMock, :charge, fn _creds, _request -> {:error, :rejected} end)

    assert :ok =
             perform_job(ChargeOrder, %{
               "payment_id" => payment.id,
               "org_id" => org.id,
               "wallet_msisdn" => "252611111111"
             })

    assert Repo.get(Payment, payment.id).status == :failed
  end

  test "a payment already resolved by a beaten-us-to-it callback is skipped, not double-charged",
       %{org: org, payment: payment} do
    payment |> Ecto.Changeset.change(status: :succeeded) |> Repo.update!()

    assert :ok =
             perform_job(ChargeOrder, %{
               "payment_id" => payment.id,
               "org_id" => org.id,
               "wallet_msisdn" => "252611111111"
             })
  end
end

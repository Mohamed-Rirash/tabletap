defmodule Tabletap.Payments.Workers.ProcessCallbackTest do
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Cart
  alias Tabletap.Payments
  alias Tabletap.Payments.Payment
  alias Tabletap.Payments.Workers.ProcessCallback
  alias Tabletap.Repo

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

    %{payment: payment}
  end

  test "an APPROVED payload resolves the payment via requestId", %{payment: payment} do
    payload = %{
      "requestId" => payment.id,
      "transactionId" => "waafi-txn-1",
      "params" => %{"state" => "APPROVED"}
    }

    assert :ok = perform_job(ProcessCallback, %{"payload" => payload})
    assert Repo.get(Payment, payment.id).status == :succeeded
  end

  test "a terminal failure state resolves to confirm_failed", %{payment: payment} do
    payload = %{"requestId" => payment.id, "params" => %{"state" => "DECLINED"}}

    assert :ok = perform_job(ProcessCallback, %{"payload" => payload})
    assert Repo.get(Payment, payment.id).status == :failed
  end

  test "a payload with no requestId is silently dropped, not a crash" do
    payload = %{"params" => %{"state" => "APPROVED"}}
    assert :ok = perform_job(ProcessCallback, %{"payload" => payload})
  end

  test "a requestId that isn't a real payment is silently dropped" do
    payload = %{"requestId" => Ecto.UUID.generate(), "params" => %{"state" => "APPROVED"}}
    assert :ok = perform_job(ProcessCallback, %{"payload" => payload})
  end

  test "an unrecognized state is a no-op, not a crash", %{payment: payment} do
    payload = %{"requestId" => payment.id, "params" => %{"state" => "SOMETHING_NEW"}}

    assert :ok = perform_job(ProcessCallback, %{"payload" => payload})
    assert Repo.get(Payment, payment.id).status == :pending
  end
end

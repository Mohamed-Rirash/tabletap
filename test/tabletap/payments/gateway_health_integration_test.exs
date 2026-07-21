defmodule Tabletap.Payments.GatewayHealthIntegrationTest do
  @moduledoc """
  `Payments.resolve_charge_result/2` feeding `GatewayHealth`
  (build-plan.md Feature 21) — `async: false` and deliberately its own
  file, separate from `payments_test.exs`: `GatewayHealth` is shared,
  process-independent ETS state, and asserting on its cumulative streak
  would be racy against other `async: true` payments tests calling
  `resolve_charge_result/2` concurrently.
  """
  use Tabletap.DataCase, async: false

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Cart
  alias Tabletap.Payments
  alias Tabletap.Payments.GatewayHealth

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

    GatewayHealth.record_success()

    %{scope: scope, item: item}
  end

  defp pending_payment(scope, item) do
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    {:ok, payment} = Payments.charge_order(scope, order, "252611111111")
    payment
  end

  test "an approved charge records a gateway success", %{scope: scope, item: item} do
    payment = pending_payment(scope, item)
    GatewayHealth.record_failure()
    GatewayHealth.record_failure()

    Payments.resolve_charge_result(payment.id, {:ok, %{provider_txn_id: "t1", state: :approved}})

    refute GatewayHealth.degraded?()
  end

  test "3 consecutive :timeout results flip the gateway degraded", %{scope: scope, item: item} do
    for _ <- 1..3 do
      payment = pending_payment(scope, item)
      Payments.resolve_charge_result(payment.id, {:error, :timeout})
    end

    assert GatewayHealth.degraded?()
  end

  test "an ambiguous connection error also counts toward degraded", %{scope: scope, item: item} do
    for _ <- 1..3 do
      payment = pending_payment(scope, item)
      Payments.resolve_charge_result(payment.id, {:error, :econnrefused})
    end

    assert GatewayHealth.degraded?()
  end

  test "a business decline (:rejected) is a real response — never counts toward degraded", %{
    scope: scope,
    item: item
  } do
    for _ <- 1..5 do
      payment = pending_payment(scope, item)
      Payments.resolve_charge_result(payment.id, {:error, :rejected})
    end

    refute GatewayHealth.degraded?()
  end

  test "a provider-reported failure code is a real response — never counts toward degraded", %{
    scope: scope,
    item: item
  } do
    for _ <- 1..5 do
      payment = pending_payment(scope, item)
      Payments.resolve_charge_result(payment.id, {:error, {:provider, "5206"}})
    end

    refute GatewayHealth.degraded?()
  end
end

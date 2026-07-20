defmodule Tabletap.OffboardingTest do
  @moduledoc """
  `Tabletap.Offboarding` — the 90-day archive-then-hard-delete
  (design-qa.md Q15/Q31/Q54): an account-holding customer's order
  survives as an anonymized platform stub, a succeeded payment
  survives as a flat dispute-evidence snapshot, and the org itself is
  gone.
  """
  use Tabletap.DataCase, async: true

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Ordering, Payments, Repo}
  alias Tabletap.Offboarding
  alias Tabletap.Offboarding.{PaymentDisputeRecord, PlatformOrderArchive}
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
  alias Tabletap.Tenants.Org

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue}

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    %{org: org, venue: venue, scope: scope, item: item}
  end

  test "archives an account-holding customer's order and a payment's dispute evidence, then deletes the org",
       %{
         org: org,
         venue: venue,
         scope: scope,
         item: item
       } do
    customer = Tabletap.AccountsFixtures.user_fixture()
    %{membership: cashier} = cashier_fixture(org, venue)
    cashier_scope = %{scope | role: :cashier, membership: cashier}

    guest_token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(cashier_scope, guest_token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(cashier_scope, cart)
    {:ok, _payment} = Payments.settle_cash_now(cashier_scope, order, cashier)
    {:ok, _} = Ordering.link_guest_orders_to_customer(customer, guest_token)

    order = Ordering.get_order(scope, order.id)

    Enum.reduce([:accepted, :preparing, :ready, :served], order, fn status, acc ->
      {:ok, moved} = OrderStateMachine.transition(scope, acc, status)
      moved
    end)

    assert {:ok, _} = Offboarding.archive_and_hard_delete(org)

    [archive] = Repo.all(PlatformOrderArchive, skip_org_id: true)
    assert archive.customer_user_id == customer.id
    assert archive.venue_name_snapshot == venue.name
    assert Money.equal?(archive.total, Money.new!(:USD, "3.50"))
    assert archive.items == %{"items" => [%{"name" => "Latte", "qty" => 1}]}

    [dispute] = Repo.all(PaymentDisputeRecord, skip_org_id: true)
    assert dispute.org_name_snapshot == org.name
    assert dispute.provider == "cash"
    assert Money.equal?(dispute.amount, Money.new!(:USD, "3.50"))
    assert DateTime.compare(dispute.retain_until, DateTime.utc_now()) == :gt

    refute Repo.get(Org, org.id, skip_org_id: true)
  end

  test "a guest order (no account) leaves no platform archive behind", %{scope: scope, item: item} do
    order = checked_out(scope, item)
    %{org: org} = scope

    assert {:ok, _} = Offboarding.archive_and_hard_delete(org)
    assert Repo.all(PlatformOrderArchive, skip_org_id: true) == []
    refute Repo.get(Org, order.org_id, skip_org_id: true)
  end

  describe "purge_expired_dispute_records/0" do
    test "purges only records whose retain_until has passed" do
      expired =
        %PaymentDisputeRecord{}
        |> Ecto.Changeset.change(%{
          org_name_snapshot: "Old Org",
          order_number: 1,
          order_placed_at: DateTime.utc_now(:second),
          provider: "cash",
          amount: Money.new!(:USD, "1.00"),
          retain_until: DateTime.add(DateTime.utc_now(:second), -1, :day)
        })
        |> Repo.insert!()

      still_retained =
        %PaymentDisputeRecord{}
        |> Ecto.Changeset.change(%{
          org_name_snapshot: "Fresh Org",
          order_number: 2,
          order_placed_at: DateTime.utc_now(:second),
          provider: "cash",
          amount: Money.new!(:USD, "1.00"),
          retain_until: DateTime.add(DateTime.utc_now(:second), 30, :day)
        })
        |> Repo.insert!()

      Offboarding.purge_expired_dispute_records()

      refute Repo.get(PaymentDisputeRecord, expired.id, skip_org_id: true)
      assert Repo.get(PaymentDisputeRecord, still_retained.id, skip_org_id: true)
    end
  end

  defp checked_out(scope, item) do
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    order
  end
end

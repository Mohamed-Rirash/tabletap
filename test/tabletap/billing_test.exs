defmodule Tabletap.BillingTest do
  @moduledoc """
  `Tabletap.Billing` — invoice period computation, the collection
  idempotency guard, and the `subscription_status` state machine
  (active on success, past_due on a first miss, canceled on a second
  consecutive one). Provider calls mocked via `Tabletap.Payments.ProviderMock`
  (Mox) — no test hits a real provider API (code-standards.md).
  """
  use Tabletap.DataCase, async: true

  import Mox
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Billing
  alias Tabletap.Billing.Invoice
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Cart
  alias Tabletap.Payments.{PlatformFeeLedgerEntry, ProviderMock}
  alias Tabletap.Repo

  setup :verify_on_exit!

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)

    # Simulate the trial having already ended, with a wallet on file —
    # the state most of these tests actually want to exercise.
    org =
      org
      |> Ecto.Changeset.change(
        trial_ends_at: DateTime.add(DateTime.utc_now(:second), -1, :day),
        billing_wallet_msisdn: "252634000000"
      )
      |> Repo.update!()

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

    %{org: org, venue: venue, order: order}
  end

  describe "next_period/1 and due?/2" do
    test "the first period starts at trial_ends_at, 30 days long", %{org: org} do
      {start, finish} = Billing.next_period(org)
      assert start == DateTime.to_date(org.trial_ends_at)
      assert finish == Date.add(start, 29)
    end

    test "due?/2 is true once the period has started", %{org: org} do
      {start, _finish} = Billing.next_period(org)
      assert Billing.due?(org, start)
      assert Billing.due?(org, Date.add(start, 5))
      refute Billing.due?(org, Date.add(start, -1))
    end

    test "the next period after an invoice starts 30 days after that invoice's own start", %{
      org: org
    } do
      {start, finish} = Billing.next_period(org)

      {:ok, invoice} =
        %Invoice{}
        |> Invoice.changeset(%{
          org_id: org.id,
          plan: org.plan,
          plan_amount: Money.new!(:USD, "40.00"),
          period_start: start,
          period_end: finish
        })
        |> Repo.insert()

      {next_start, next_finish} = Billing.next_period(org)
      assert next_start == Date.add(invoice.period_start, 30)
      assert next_finish == Date.add(next_start, 29)
    end
  end

  describe "collect_invoice/1" do
    test "no wallet on file is a routine no-op, not an error worth alerting on", %{org: org} do
      org = org |> Ecto.Changeset.change(billing_wallet_msisdn: nil) |> Repo.update!()
      assert {:error, :no_wallet_on_file} = Billing.collect_invoice(org)
    end

    test "not yet due is a routine no-op", %{org: org} do
      org =
        org
        |> Ecto.Changeset.change(trial_ends_at: DateTime.add(DateTime.utc_now(:second), 5, :day))
        |> Repo.update!()

      assert {:error, :not_due} = Billing.collect_invoice(org)
    end

    test "a successful charge settles matching-currency fees and activates the org", %{
      org: org,
      venue: venue,
      order: order
    } do
      ledger_entry =
        %PlatformFeeLedgerEntry{}
        |> Ecto.Changeset.change(%{
          org_id: org.id,
          venue_id: venue.id,
          order_id: order.id,
          amount: Money.new!(:USD, "1.50"),
          accrued_at: DateTime.utc_now(:second)
        })
        |> Repo.insert!()

      expect(ProviderMock, :charge, fn creds, request ->
        assert creds.merchant_uid == "test-platform-merchant"
        assert request.wallet_msisdn == org.billing_wallet_msisdn
        assert Money.equal?(request.amount, Money.new!(:USD, "41.50"))
        {:ok, %{provider_txn_id: "platform-txn-1", state: :approved}}
      end)

      assert {:ok, %{invoice: invoice, org: updated_org}} = Billing.collect_invoice(org)
      assert invoice.status == :succeeded
      assert invoice.provider_txn_id == "platform-txn-1"
      assert updated_org.subscription_status == :active

      reloaded = Repo.get!(PlatformFeeLedgerEntry, ledger_entry.id)
      assert reloaded.settled_at != nil
      assert reloaded.invoice_id == invoice.id
    end

    test "a declined charge moves the org to past_due, not canceled, on the first miss", %{
      org: org
    } do
      expect(ProviderMock, :charge, fn _creds, _request -> {:error, :insufficient_funds} end)

      assert {:error, %{invoice: invoice, org: updated_org}} = Billing.collect_invoice(org)
      assert invoice.status == :failed
      assert updated_org.subscription_status == :past_due
    end

    test "a second consecutive decline moves an already past_due org to canceled", %{org: org} do
      org = org |> Ecto.Changeset.change(subscription_status: :past_due) |> Repo.update!()

      expect(ProviderMock, :charge, fn _creds, _request -> {:error, :rejected} end)

      assert {:error, %{org: updated_org}} = Billing.collect_invoice(org)
      assert updated_org.subscription_status == :canceled
    end

    test "collecting once advances next_period/1 so an immediate re-run isn't due again", %{
      org: org
    } do
      expect(ProviderMock, :charge, fn _creds, _request ->
        {:ok, %{provider_txn_id: "once", state: :approved}}
      end)

      {first_start, _} = Billing.next_period(org)
      assert {:ok, %{org: org}} = Billing.collect_invoice(org)

      {next_start, _} = Billing.next_period(org)
      assert next_start == Date.add(first_start, 30)
      assert {:error, :not_due} = Billing.collect_invoice(org)
    end
  end

  describe "expire_unpaid_trial/1" do
    test "converts straight to canceled, no past_due step", %{org: org} do
      org =
        org
        |> Ecto.Changeset.change(subscription_status: :trialing, billing_wallet_msisdn: nil)
        |> Repo.update!()

      assert {:ok, updated_org} = Billing.expire_unpaid_trial(org)
      assert updated_org.subscription_status == :canceled
    end
  end
end

defmodule Tabletap.Billing.Workers.CollectMonthlyInvoicesTest do
  @moduledoc """
  `Workers.CollectMonthlyInvoices` — the nightly dispatch: a trialing
  org with no wallet on file expires unattended (design-qa.md Q29), a
  trialing org with a wallet or an active/past_due org goes through
  `Billing.collect_invoice/1`, a canceled org is left alone.
  """
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Mox
  import Tabletap.TenantsFixtures

  alias Tabletap.Billing.Workers.CollectMonthlyInvoices
  alias Tabletap.Payments.ProviderMock
  alias Tabletap.Repo

  setup :verify_on_exit!

  setup do
    %{org: org} = org_fixture()
    Repo.put_org_id(org.id)
    %{org: org}
  end

  test "a trialing org past its trial_ends_at with no wallet on file is canceled", %{org: org} do
    org
    |> Ecto.Changeset.change(trial_ends_at: DateTime.add(DateTime.utc_now(:second), -1, :day))
    |> Repo.update!()

    assert :ok = perform_job(CollectMonthlyInvoices, %{})

    assert Repo.get!(Tabletap.Tenants.Org, org.id, skip_org_id: true).subscription_status ==
             :canceled
  end

  test "a trialing org still within its trial is left alone", %{org: org} do
    assert :ok = perform_job(CollectMonthlyInvoices, %{})

    assert Repo.get!(Tabletap.Tenants.Org, org.id, skip_org_id: true).subscription_status ==
             :trialing
  end

  test "a trialing org past trial_ends_at with a wallet on file is billed instead of canceled", %{
    org: org
  } do
    org
    |> Ecto.Changeset.change(
      trial_ends_at: DateTime.add(DateTime.utc_now(:second), -1, :day),
      billing_wallet_msisdn: "252634000000"
    )
    |> Repo.update!()

    expect(ProviderMock, :charge, fn _creds, _request ->
      {:ok, %{provider_txn_id: "t1", state: :approved}}
    end)

    assert :ok = perform_job(CollectMonthlyInvoices, %{})

    assert Repo.get!(Tabletap.Tenants.Org, org.id, skip_org_id: true).subscription_status ==
             :active
  end

  test "a canceled org is left alone entirely", %{org: org} do
    org |> Ecto.Changeset.change(subscription_status: :canceled) |> Repo.update!()

    assert :ok = perform_job(CollectMonthlyInvoices, %{})

    assert Repo.get!(Tabletap.Tenants.Org, org.id, skip_org_id: true).subscription_status ==
             :canceled
  end
end

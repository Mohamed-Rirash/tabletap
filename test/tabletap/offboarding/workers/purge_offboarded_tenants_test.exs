defmodule Tabletap.Offboarding.Workers.PurgeOffboardedTenantsTest do
  @moduledoc """
  `Workers.PurgeOffboardedTenants` — only orgs 90+ days into
  offboarding get hard-deleted; a fresh offboarding request or an org
  that never asked to leave is left alone.
  """
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Tabletap.TenantsFixtures

  alias Tabletap.Offboarding.Workers.PurgeOffboardedTenants
  alias Tabletap.Repo
  alias Tabletap.Tenants.Org

  test "hard-deletes an org 90+ days into offboarding" do
    %{org: org} = org_fixture()

    org
    |> Ecto.Changeset.change(
      offboarding_requested_at: DateTime.add(DateTime.utc_now(:second), -91, :day)
    )
    |> Repo.update!()

    assert :ok = perform_job(PurgeOffboardedTenants, %{})

    refute Repo.get(Org, org.id, skip_org_id: true)
  end

  test "leaves an org whose offboarding request is still under 90 days alone" do
    %{org: org} = org_fixture()

    org
    |> Ecto.Changeset.change(
      offboarding_requested_at: DateTime.add(DateTime.utc_now(:second), -5, :day)
    )
    |> Repo.update!()

    assert :ok = perform_job(PurgeOffboardedTenants, %{})

    assert Repo.get(Org, org.id, skip_org_id: true)
  end

  test "leaves an org that never requested offboarding alone" do
    %{org: org} = org_fixture()

    assert :ok = perform_job(PurgeOffboardedTenants, %{})

    assert Repo.get(Org, org.id, skip_org_id: true)
  end
end

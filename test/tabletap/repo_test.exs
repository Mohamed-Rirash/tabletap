defmodule Tabletap.RepoTest do
  use Tabletap.DataCase, async: true

  alias Tabletap.Tenants.Venue

  import Tabletap.TenantsFixtures

  describe "tenant enforcement" do
    test "querying a tenant-owned table without org context raises" do
      org_fixture()
      Repo.put_org_id(nil)

      assert_raise RuntimeError, ~r/expected org_id or skip_org_id/, fn ->
        Repo.all(Venue)
      end
    end

    test "querying with put_org_id/1 set scopes automatically, no explicit where needed" do
      %{org: org, venue: venue} = org_fixture()
      # A second org's venue must never appear once org_id is scoped below.
      org_fixture()

      Repo.put_org_id(org.id)

      assert [%Venue{id: id}] = Repo.all(Venue)
      assert id == venue.id
    end

    test "skip_org_id: true bypasses the check" do
      org_fixture()
      Repo.put_org_id(nil)

      assert is_list(Repo.all(Venue, skip_org_id: true))
    end

    test "get_org_id/0 reflects the last put_org_id/1 call" do
      refute Repo.get_org_id()

      Repo.put_org_id("some-org-id")
      assert Repo.get_org_id() == "some-org-id"
    end
  end
end

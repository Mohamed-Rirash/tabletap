defmodule Tabletap.TenantsTablesTest do
  @moduledoc "Tables — the Feature 06 half of the Tenants context (build-plan.md)."
  use Tabletap.DataCase, async: true

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Repo, Tenants}
  alias Tabletap.Tenants.Table

  import Tabletap.TenantsFixtures

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    %{scope: %Scope{org: org, venue: venue}, org: org, venue: venue}
  end

  describe "create_table/2" do
    test "creates a table with a fresh opaque QR token", %{scope: scope, org: org, venue: venue} do
      assert {:ok, %Table{} = table} =
               Tenants.create_table(scope, %{"number" => "12", "label" => "Window booth"})

      assert table.number == "12"
      assert table.label == "Window booth"
      assert table.active
      assert is_nil(table.archived_at)
      assert table.org_id == org.id
      assert table.venue_id == venue.id
      # url-safe, unguessable, and not something the caller could have set.
      assert byte_size(table.qr_token) >= 20
      refute table.qr_token =~ ~r/[^A-Za-z0-9_-]/
    end

    test "trims whitespace and requires a number", %{scope: scope} do
      assert {:ok, table} = Tenants.create_table(scope, %{"number" => "  A3  "})
      assert table.number == "A3"

      assert {:error, changeset} = Tenants.create_table(scope, %{"number" => ""})
      assert %{number: ["can't be blank"]} = errors_on(changeset)
    end

    test "two live tables can't share a number in the same venue", %{scope: scope} do
      assert {:ok, _} = Tenants.create_table(scope, %{"number" => "7"})
      assert {:error, changeset} = Tenants.create_table(scope, %{"number" => "7"})
      assert %{number: ["has already been taken"]} = errors_on(changeset)
    end

    test "an archived number can be reused", %{scope: scope} do
      {:ok, first} = Tenants.create_table(scope, %{"number" => "9"})
      {:ok, _} = Tenants.archive_table(scope, first)

      assert {:ok, _} = Tenants.create_table(scope, %{"number" => "9"})
    end

    test "the same number is fine in a different venue of the same org", %{scope: scope, org: org} do
      other_venue = venue_fixture(org)
      other_scope = %Scope{org: scope.org, venue: other_venue}

      assert {:ok, _} = Tenants.create_table(scope, %{"number" => "1"})
      assert {:ok, _} = Tenants.create_table(other_scope, %{"number" => "1"})
    end
  end

  describe "list_tables/1 and get_table/2" do
    test "lists only the venue's non-archived tables", %{scope: scope} do
      keep = table_fixture(scope, %{"number" => "1"})
      gone = table_fixture(scope, %{"number" => "2"})
      {:ok, _} = Tenants.archive_table(scope, gone)

      ids = scope |> Tenants.list_tables() |> Enum.map(& &1.id)
      assert ids == [keep.id]
    end

    test "get_table/2 returns a scoped table, nil for archived", %{scope: scope} do
      table = table_fixture(scope)
      assert Tenants.get_table(scope, table.id).id == table.id

      {:ok, _} = Tenants.archive_table(scope, table)
      assert Tenants.get_table(scope, table.id) == nil
    end
  end

  describe "update_table/3 and rotate_qr_token/2" do
    test "updates number, label, and active", %{scope: scope} do
      table = table_fixture(scope, %{"number" => "3"})

      assert {:ok, updated} =
               Tenants.update_table(scope, table, %{
                 "number" => "3A",
                 "label" => "Patio",
                 "active" => false
               })

      assert updated.number == "3A"
      assert updated.label == "Patio"
      refute updated.active
      # Rotation is a separate action — a plain edit never changes the token.
      assert updated.qr_token == table.qr_token
    end

    test "rotate_qr_token/2 issues a new token and abandons the old one", %{scope: scope} do
      table = table_fixture(scope)
      old = table.qr_token

      assert {:ok, rotated} = Tenants.rotate_qr_token(scope, table)
      assert rotated.qr_token != old

      # The old token no longer resolves — the printed code is dead (Q7).
      assert Tenants.get_table_by_qr_token(old) == nil
      assert Tenants.get_table_by_qr_token(rotated.qr_token).id == table.id
    end
  end

  describe "get_table_by_qr_token/1 (public scan resolution)" do
    test "resolves an active table with venue + org preloaded", %{scope: scope, venue: venue} do
      table = table_fixture(scope)

      resolved = Tenants.get_table_by_qr_token(table.qr_token)
      assert resolved.id == table.id
      assert resolved.venue.id == venue.id
      assert resolved.venue.org.id == scope.org.id
    end

    test "returns nil for unknown, archived, or deactivated tables", %{scope: scope} do
      assert Tenants.get_table_by_qr_token("nope-not-a-token") == nil

      archived = table_fixture(scope, %{"number" => "50"})
      {:ok, _} = Tenants.archive_table(scope, archived)
      assert Tenants.get_table_by_qr_token(archived.qr_token) == nil

      inactive = table_fixture(scope, %{"number" => "51"})
      {:ok, _} = Tenants.update_table(scope, inactive, %{"active" => false})
      assert Tenants.get_table_by_qr_token(inactive.qr_token) == nil
    end
  end

  describe "tenant isolation" do
    test "one venue can't see or fetch another tenant's table" do
      %{venue_a: venue_a, org_a: org_a, venue_b: venue_b, org_b: org_b} = two_orgs()

      scope_a = %Scope{org: org_a, venue: venue_a}
      scope_b = %Scope{org: org_b, venue: venue_b}

      Repo.put_org_id(org_a.id)
      a_table = table_fixture(scope_a)

      # Org B's scope must not list or fetch org A's table.
      Repo.put_org_id(org_b.id)
      assert Tenants.list_tables(scope_b) == []
      assert Tenants.get_table(scope_b, a_table.id) == nil
    end
  end
end

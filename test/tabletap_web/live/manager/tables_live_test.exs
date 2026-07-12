defmodule TabletapWeb.Manager.TablesLiveTest do
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Repo, Tenants}

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/tables")
    end
  end

  describe "as an owner" do
    setup :register_and_log_in_owner

    setup %{org: org} do
      Repo.put_org_id(org.id)
      :ok
    end

    test "shows an empty state with no tables yet", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/tables")
      assert html =~ "No tables yet"
    end

    test "creates a table", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/tables")

      html =
        lv
        |> form("#table-form", table: %{number: "12", label: "Window booth"})
        |> render_submit()

      assert html =~ "Table 12"
      assert html =~ "Window booth"
      assert [table] = Tenants.list_tables(scope)
      assert table.number == "12"
    end

    test "surfaces a duplicate-number error inline", %{conn: conn, scope: scope} do
      _ = table_fixture(scope, %{"number" => "7"})
      {:ok, lv, _html} = live(conn, ~p"/tables")

      html =
        lv
        |> form("#table-form", table: %{number: "7"})
        |> render_submit()

      assert html =~ "has already been taken"
    end

    test "rotates a table's QR token", %{conn: conn, scope: scope} do
      table = table_fixture(scope, %{"number" => "5"})
      {:ok, lv, _html} = live(conn, ~p"/tables")

      lv |> element("#table-#{table.id} button", "Rotate QR") |> render_click()

      assert Tenants.get_table(scope, table.id).qr_token != table.qr_token
    end

    test "archives a table", %{conn: conn, scope: scope} do
      table = table_fixture(scope, %{"number" => "8"})
      {:ok, lv, _html} = live(conn, ~p"/tables")

      html = lv |> element("#table-#{table.id} button", "Archive") |> render_click()

      refute html =~ "Table 8"
      assert Tenants.list_tables(scope) == []
    end

    test "edits an existing table", %{conn: conn, scope: scope} do
      table = table_fixture(scope, %{"number" => "4", "label" => "Original"})
      {:ok, lv, _html} = live(conn, ~p"/tables")

      html = lv |> element("#table-#{table.id} button", "Edit") |> render_click()

      # The form switches to edit mode, pre-filled from the target table.
      assert html =~ "Edit table"
      assert html =~ "Save changes"
      assert html =~ ~s(value="4")

      html =
        lv
        |> form("#table-form", table: %{number: "4B", label: "Updated"})
        |> render_submit()

      assert html =~ "Table 4B"
      assert html =~ "Updated"
      # Saving returns the form to :new mode.
      assert html =~ "New table"

      updated = Tenants.get_table(scope, table.id)
      assert updated.number == "4B"
      assert updated.label == "Updated"
    end

    test "cancels an edit, discarding in-progress changes", %{conn: conn, scope: scope} do
      table = table_fixture(scope, %{"number" => "6", "label" => "Keep me"})
      {:ok, lv, _html} = live(conn, ~p"/tables")

      html = lv |> element("#table-#{table.id} button", "Edit") |> render_click()
      assert html =~ "Edit table"

      html = lv |> element("#table-form button", "Cancel") |> render_click()
      assert html =~ "New table"
      refute html =~ "Save changes"

      unchanged = Tenants.get_table(scope, table.id)
      assert unchanged.number == "6"
      assert unchanged.label == "Keep me"
    end

    test "rotating, archiving, or editing a table id no longer in scope fails gracefully, not with a crash",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/tables")
      bogus_id = Ecto.UUID.generate()

      # Before the fix, each of these raised FunctionClauseError (a 500)
      # instead of a handled deny — reachable via a forged/stale
      # phx-value-id that never was (or no longer is) in this venue's
      # own scoped table list.
      html = render_click(lv, "rotate_token", %{"id" => bogus_id})
      assert html =~ "no longer available"

      html = render_click(lv, "archive_table", %{"id" => bogus_id})
      assert html =~ "no longer available"

      html = render_click(lv, "edit_table", %{"id" => bogus_id})
      assert html =~ "no longer available"
      assert html =~ "New table"
    end

    test "print sheet renders a QR svg per table", %{conn: conn, scope: scope} do
      table = table_fixture(scope, %{"number" => "3"})
      {:ok, _lv, html} = live(conn, ~p"/tables/print")

      assert html =~ "Table 3"
      assert html =~ "<svg"
      # The anti-phishing plain-text scan URL is printed under the code (Q7).
      assert html =~ "/t/#{table.qr_token}"
    end
  end

  describe "tenant isolation" do
    test "an owner can't rotate another org's table", %{conn: conn} do
      %{venue_a: venue_a, org_a: org_a} = two_orgs()
      Repo.put_org_id(org_a.id)
      other_table = table_fixture(%Scope{org: org_a, venue: venue_a}, %{"number" => "99"})

      %{conn: conn} = register_and_log_in_owner(%{conn: conn})
      {:ok, lv, html} = live(conn, ~p"/tables")

      # The other org's table simply isn't on this owner's board.
      refute html =~ "Table 99"
      refute has_element?(lv, "#table-#{other_table.id}")
    end
  end
end

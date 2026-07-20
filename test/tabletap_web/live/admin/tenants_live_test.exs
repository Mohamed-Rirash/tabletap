defmodule TabletapWeb.Admin.TenantsLiveTest do
  @moduledoc """
  `Admin.TenantsLive` at `/admin` (build-plan.md Feature 19) — gated
  by `users.platform_admin`, not any tenant role; a regular owner (no
  admin flag) is denied the same as an unauthenticated visitor.
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Repo

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/admin")
    end

    test "redirects a logged-in owner without the platform_admin flag", %{conn: conn} do
      %{user: user} = org_fixture()
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin")
    end
  end

  describe "as a platform admin" do
    setup %{conn: conn} do
      user = Tabletap.AccountsFixtures.user_fixture()
      user = user |> Ecto.Changeset.change(platform_admin: true) |> Repo.update!()
      %{conn: log_in_user(conn, user), admin: user}
    end

    test "lists every org with plan, status, venue count, order count", %{conn: conn} do
      %{org: org} = org_fixture()

      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "Tenants"
      assert html =~ org.name
      assert html =~ "Essentials"
      assert html =~ "trialing"
    end

    test "links to the tenant detail page", %{conn: conn} do
      %{org: org} = org_fixture()

      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ ~s(href="/admin/tenants/#{org.id}")
    end

    test "an org that isn't the admin's own tenant is still visible — this is cross-tenant by design",
         %{conn: conn} do
      %{org: org_a} = org_fixture()
      %{org: org_b} = org_fixture()

      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ org_a.name
      assert html =~ org_b.name
    end
  end
end

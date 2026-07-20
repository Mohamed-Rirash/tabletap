defmodule TabletapWeb.Manager.OrgExportControllerTest do
  @moduledoc """
  `Manager.OrgExportController` — the org data export download
  (build-plan.md Feature 19), owner-only.
  """
  use TabletapWeb.ConnCase, async: true

  alias Tabletap.Repo
  alias Tabletap.Tenants.Membership

  setup :register_and_log_in_owner

  test "an owner downloads a zip containing the export CSVs", %{conn: conn} do
    conn = get(conn, ~p"/settings/billing/export.zip")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/zip"
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "attachment"

    {:ok, entries} = :zip.unzip(response(conn, 200), [:memory])
    names = Enum.map(entries, fn {name, _content} -> to_string(name) end)

    assert "menu.csv" in names
    assert "orders.csv" in names
    assert "ingredients.csv" in names
  end

  test "a manager is denied — this is owner-only", %{org: org, venue: venue} do
    manager_user = Tabletap.AccountsFixtures.user_fixture()

    {:ok, _} =
      %Membership{}
      |> Membership.changeset(%{
        org_id: org.id,
        venue_id: venue.id,
        user_id: manager_user.id,
        role: :manager
      })
      |> Repo.insert()

    conn = log_in_user(build_conn(), manager_user)
    conn = get(conn, ~p"/settings/billing/export.zip")

    assert redirected_to(conn) == "/"
  end
end

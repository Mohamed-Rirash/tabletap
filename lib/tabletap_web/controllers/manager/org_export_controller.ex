defmodule TabletapWeb.Manager.OrgExportController do
  @moduledoc """
  Full org data export (build-plan.md Feature 19; design-qa.md Q15) —
  a zip of `Tenants.export_org_data/1`'s CSVs, owner-only. The one
  self-serve way an owner gets their data out before offboarding.
  """
  use TabletapWeb, :controller

  alias Tabletap.Tenants

  def show(conn, _params) do
    scope = conn.assigns.current_scope
    files = Tenants.export_org_data(scope)

    entries = Enum.map(files, fn {name, content} -> {String.to_charlist(name), content} end)
    {:ok, {_name, zip_binary}} = :zip.create(~c"export.zip", entries, [:memory])

    conn
    |> put_resp_content_type("application/zip")
    |> put_resp_header(
      "content-disposition",
      "attachment; filename=\"#{scope.org.slug}-export.zip\""
    )
    |> send_resp(200, zip_binary)
  end
end

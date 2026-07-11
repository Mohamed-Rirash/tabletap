defmodule TabletapWeb.VenueController do
  @moduledoc """
  The venue switcher (build-plan.md Feature 03: "Venue switcher for
  multi-venue orgs"). A plain controller action, not a LiveView event —
  the picked venue has to persist in the session for future requests, and
  a LiveView process can't write HTTP session cookies itself.
  """
  use TabletapWeb, :controller

  alias Tabletap.Tenants

  def switch(conn, %{"venue_id" => venue_id}) do
    case Tenants.switch_venue(conn.assigns.current_scope, venue_id) do
      {:ok, venue} ->
        conn
        |> put_session(:current_venue_id, venue.id)
        |> redirect(to: ~p"/dashboard")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, gettext("That venue isn't part of your organization."))
        |> redirect(to: ~p"/dashboard")
    end
  end

  # A malformed/missing venue_id (no real caller does this — the switcher
  # form always includes it) still gets a handled response, not a raw
  # Phoenix.ActionClauseError.
  def switch(conn, _params) do
    conn
    |> put_flash(:error, gettext("Choose a venue to switch to."))
    |> redirect(to: ~p"/dashboard")
  end
end

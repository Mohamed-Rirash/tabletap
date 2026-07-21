defmodule TabletapWeb.Public.TableController do
  @moduledoc """
  Entry point for a scanned table QR: `GET /t/:qr_token` (build-plan.md
  Feature 06; architecture.md "Customer Identity & QR Flow"). Resolves
  the opaque token to its table, remembers the table in the session, and
  hands off to the public menu LiveView.

  A plain controller, not a LiveView — the resolved table has to persist
  in the HTTP session (so a later reconnect/deploy still knows which
  table the guest is sitting at, design-qa.md Q50), and a LiveView
  process can't write session cookies itself.

  An unresolved token renders an honest not-found page directly (never a
  flash-then-redirect to the marketing homepage) — the root layout
  deliberately has no sitewide `<.flash_group>` (it would double-render on
  every LiveView page, which mounts its own via `Layouts.app`/`Layouts.manager`),
  so a flash set here before redirecting to `/` would silently never be
  seen. A guest who scans a torn/stale QR needs to know what happened, not
  land on the SaaS marketing page (design-qa.md Q7/Q19 "honest, never a
  raw error").

  The venue-open / Busy-Mode / subscription gates named in architecture.md
  arrive with the ordering loop (Feature 08); for now this only resolves
  and displays.
  """
  use TabletapWeb, :controller

  alias Tabletap.Tenants
  alias TabletapWeb.RateLimiter

  # Generous — a busy venue's own wifi commonly NATs many real customers
  # behind one IP, and a legitimate table full of people scanning within
  # the same minute is normal, not abuse (build-plan.md Feature 22).
  @rate_limit_opts [max: 30, window_ms: 60_000]

  def show(conn, %{"qr_token" => qr_token}) do
    ip = RateLimiter.client_ip_from_conn(conn)

    if RateLimiter.check({:qr_scan, ip}, @rate_limit_opts) == :ok do
      resolve_table(conn, qr_token)
    else
      conn
      |> assign(:hide_utility_bar, true)
      |> put_status(:too_many_requests)
      |> render(:rate_limited)
    end
  end

  defp resolve_table(conn, qr_token) do
    case Tenants.get_table_by_qr_token(qr_token) do
      nil ->
        conn
        |> assign(:hide_utility_bar, true)
        |> put_status(:not_found)
        |> render(:not_found)

      table ->
        conn
        |> put_session(:table_id, table.id)
        |> redirect(to: ~p"/venues/#{table.venue.slug}/menu")
    end
  end
end

defmodule TabletapWeb.HealthController do
  use TabletapWeb, :controller

  # Liveness probe for the deploy platform/CI — no auth, no session, no DB
  # dependency (Feature 01 verify step: server boots, this returns 200).
  def show(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end

defmodule TabletapWeb.BrowserFloorController do
  @moduledoc """
  The honest "please update your browser" page `BrowserFloorPlug`
  redirects to (design-qa.md Q56) — a plain controller/template, not a
  LiveView: a browser old enough to get redirected here is exactly the
  browser we shouldn't ask to hold a WebSocket connection open.
  """
  use TabletapWeb, :controller

  def show(conn, _params) do
    conn
    |> assign(:hide_utility_bar, true)
    |> render(:show)
  end
end

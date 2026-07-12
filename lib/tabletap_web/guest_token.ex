defmodule TabletapWeb.GuestToken do
  @moduledoc """
  Restores a returning guest's identity on the public customer routes
  (build-plan.md Feature 07; design-qa.md Q13/Q50). Mirrors
  `TabletapWeb.UserAuth`'s shape: a function plug that runs once per
  request and hands the resolved value to the LiveView through the
  session, the same way `Public.TableController` already does for
  `table_id`.

  **Reading an existing cookie is the only thing this plug does.**
  Minting a brand-new `guest_token` happens lazily inside
  `Public.MenuLive`'s "add to cart" handler (architecture.md: "guest_token
  minted on first add") — not here, and not on every idle page view. A
  LiveView's connected socket can't call `put_resp_cookie/4` itself (no
  such API exists on `Phoenix.LiveView.Socket` — there is no HTTP
  response to attach a `Set-Cookie` header to mid-connection), so a fresh
  token is instead pushed to the client via `push_event/3` and written
  with a colocated hook (`document.cookie`, 30 days — Q13). The *next*
  request (a reconnect, a reload, a re-scan of the table QR) is what this
  plug then picks back up.
  """
  import Plug.Conn

  @cookie "guest_token"
  @max_age_seconds 60 * 60 * 24 * 30

  def cookie_name, do: @cookie
  def max_age_seconds, do: @max_age_seconds

  @doc "Requires `plug :fetch_cookies` earlier in the pipeline (router's :browser)."
  def fetch_guest_token(conn, _opts) do
    case conn.cookies[@cookie] do
      token when is_binary(token) and byte_size(token) > 0 ->
        put_session(conn, :guest_token, token)

      _ ->
        conn
    end
  end
end

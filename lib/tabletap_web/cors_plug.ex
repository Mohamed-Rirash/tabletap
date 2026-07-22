defmodule TabletapWeb.CorsPlug do
  @moduledoc """
  Minimal CORS support for `/api/v1` (build-plan.md Feature 24) — a
  real native iOS/Android build never sends an `Origin` header and is
  never subject to CORS at all (a browser-only enforcement mechanism),
  so this doesn't matter for the shipped mobile apps. It matters for
  verifying them: Expo's web target (`react-native-web`) *is* a
  browser, and it's the one substitute available in this sandbox for a
  physical device/emulator. A wildcard origin is safe specifically
  because this API never uses cookies for auth — bearer tokens travel
  via an explicit `Authorization` header, so there's no ambient
  credential a wildcard origin could leak.

  Hand-rolled rather than a new dependency (`cors_plug`/`corsica`) —
  code-standards.md: check Phoenix/Plug can already do this first, and
  this is a five-line plug, not something worth a new dependency for.
  """
  import Plug.Conn

  def init(opts), do: opts

  # Registered in the Endpoint (before the Router even matches a route)
  # specifically so an OPTIONS preflight can be answered here — the
  # Router only has GET/POST/DELETE routes registered under /api/v1, so
  # it would 404 an OPTIONS request before any router-pipeline plug got
  # a chance to handle it.
  def call(%{request_path: "/api/v1" <> _} = conn, _opts), do: add_cors_headers(conn)
  def call(conn, _opts), do: conn

  defp add_cors_headers(conn) do
    conn =
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")
      |> put_resp_header("access-control-allow-headers", "authorization, content-type")

    if conn.method == "OPTIONS" do
      conn |> send_resp(204, "") |> halt()
    else
      conn
    end
  end
end

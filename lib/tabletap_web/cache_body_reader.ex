defmodule TabletapWeb.CacheBodyReader do
  @moduledoc """
  Stashes the raw request body on the conn before `Plug.Parsers` consumes
  it — the WaafiPay webhook controller needs the exact original bytes to
  verify the HMAC-SHA256 signature (library-docs.md; `Jason.decode` of an
  already-decoded-and-reencoded body would produce a byte-for-byte
  different string and fail verification even on a genuine callback).
  Every other route gets normal parsed `conn.params` exactly as before —
  this only adds `conn.assigns.raw_body`, it doesn't change parsing.
  """

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    {:ok, body, Plug.Conn.assign(conn, :raw_body, body)}
  end
end

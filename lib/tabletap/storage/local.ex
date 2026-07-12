defmodule Tabletap.Storage.Local do
  @moduledoc """
  Dev/test fallback storage adapter — writes to `priv/static/uploads`
  instead of a real bucket, so Feature 04 doesn't require a provisioned
  Supabase project to build or test against. Selected automatically in
  runtime.exs when Supabase credentials aren't set (dev) or always
  (test); never selected in prod, which raises instead if unconfigured.

  Hands out an upload URL shaped exactly like `Storage.S3`'s — a same
  origin PUT endpoint (`TabletapWeb.LocalUploadController`) that just
  writes the raw request body to disk — so the LiveView upload flow
  doesn't need to know which adapter is active.
  """
  @behaviour Tabletap.Storage

  @impl true
  def presigned_upload_url(key), do: {:ok, %{url: "/uploads/local/#{key}", headers: []}}

  @impl true
  def public_url(key), do: "/uploads/#{key}"
end

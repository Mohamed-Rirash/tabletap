defmodule Tabletap.Storage.S3 do
  @moduledoc """
  Supabase Storage adapter (library-docs.md "ex_aws_s3 (photos)").
  Supabase Storage exposes an S3-compatible API, so this reuses
  `ex_aws`/`ex_aws_s3` pointed at Supabase's endpoint instead of AWS
  (config comes from runtime.exs, sourced from `.env` in dev — see
  `.env.example`) rather than a Supabase-specific client library.
  """
  @behaviour Tabletap.Storage

  @impl true
  def presigned_upload_url(key) do
    config = Application.fetch_env!(:tabletap, Tabletap.Storage)
    bucket = Keyword.fetch!(config, :bucket)

    {:ok, url} =
      ExAws.Config.new(:s3) |> ExAws.S3.presigned_url(:put, bucket, key, expires_in: 900)

    {:ok, %{url: url, headers: []}}
  end

  @impl true
  def public_url(key) do
    config = Application.fetch_env!(:tabletap, Tabletap.Storage)
    base = Keyword.fetch!(config, :public_url_base)
    base <> "/" <> key
  end
end

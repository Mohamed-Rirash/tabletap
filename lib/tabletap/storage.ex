defmodule Tabletap.Storage do
  @moduledoc """
  Object storage for menu/venue photos (build-plan.md Feature 04).

  Two adapters, selected in `config :tabletap, Tabletap.Storage, adapter:
  ...` (runtime.exs): `Tabletap.Storage.S3` (Supabase Storage's
  S3-compatible API — the real path, used whenever Supabase credentials
  are present) and `Tabletap.Storage.Local` (dev fallback when they
  aren't, and always in test — writes to `priv/static/uploads`, no
  network).

  Both adapters speak the same "direct-to-bucket presigned PUT" shape
  (library-docs.md "ex_aws_s3 (photos)") so the upload flow in
  `TabletapWeb.Manager.MenuLive` doesn't care which one is active: get a
  presigned PUT URL for a key, upload straight to it from the browser,
  store the resulting public URL on the record.
  """

  @type key :: String.t()

  @callback presigned_upload_url(key) ::
              {:ok, %{url: String.t(), headers: [{String.t(), String.t()}]}}
  @callback public_url(key) :: String.t()

  defp adapter, do: Application.fetch_env!(:tabletap, __MODULE__) |> Keyword.fetch!(:adapter)

  @doc """
  Builds a storage key for a venue's menu-item photo. Namespaced by org
  and venue so two tenants can never collide, extension preserved for
  correct content-type serving.
  """
  def menu_item_photo_key(org_id, venue_id, extension) do
    "orgs/#{org_id}/venues/#{venue_id}/menu-items/#{Ecto.UUID.generate()}#{extension}"
  end

  def presigned_upload_url(key), do: adapter().presigned_upload_url(key)
  def public_url(key), do: adapter().public_url(key)
end

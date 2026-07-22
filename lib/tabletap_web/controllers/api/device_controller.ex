defmodule TabletapWeb.Api.DeviceController do
  @moduledoc """
  build-plan.md Feature 23 Commit 5 — Expo push token registration,
  bearer-token protected (the token belongs to whichever user is
  currently signed in on the device, not a venue/membership — no scope
  needed beyond `current_api_user`).
  """
  use TabletapWeb, :controller

  alias Tabletap.Notifications

  def create(conn, params) do
    case Notifications.register_device_token(conn.assigns.current_api_user, params) do
      {:ok, _device_token} ->
        send_resp(conn, :no_content, "")

      {:error, %Ecto.Changeset{}} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_token"})
    end
  end

  def delete(conn, %{"token" => token}) do
    :ok = Notifications.unregister_device_token(conn.assigns.current_api_user, token)
    send_resp(conn, :no_content, "")
  end
end

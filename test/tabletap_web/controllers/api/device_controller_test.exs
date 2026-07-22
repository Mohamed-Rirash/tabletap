defmodule TabletapWeb.Api.DeviceControllerTest do
  @moduledoc "build-plan.md Feature 23 Commit 5 — Expo push token registration."
  use TabletapWeb.ConnCase, async: true

  import Tabletap.AccountsFixtures

  alias Tabletap.Notifications
  alias TabletapWeb.ApiAuth

  defp bearer(conn, user) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{ApiAuth.sign_access_token(user)}")
  end

  describe "POST /api/v1/devices" do
    test "registers a device token for the authenticated user", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> bearer(user)
        |> post(~p"/api/v1/devices", %{"token" => "ExponentPushToken[abc]", "platform" => "ios"})

      assert response(conn, 204)
      assert [token] = Notifications.list_device_tokens_for_user(user.id)
      assert token.token == "ExponentPushToken[abc]"
    end

    test "an unauthenticated request is rejected", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/devices", %{"token" => "ExponentPushToken[abc]"})
      assert json_response(conn, 401)
    end
  end

  describe "DELETE /api/v1/devices/:token" do
    test "removes the caller's own device token", %{conn: conn} do
      user = user_fixture()
      device_token = "ExponentPushToken[xyz]"
      {:ok, _} = Notifications.register_device_token(user, %{"token" => device_token})

      conn = conn |> bearer(user) |> delete(~p"/api/v1/devices/#{device_token}")

      assert response(conn, 204)
      assert Notifications.list_device_tokens_for_user(user.id) == []
    end
  end
end

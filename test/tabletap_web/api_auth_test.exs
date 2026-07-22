defmodule TabletapWeb.ApiAuthTest do
  use Tabletap.DataCase, async: true

  import Tabletap.AccountsFixtures

  alias TabletapWeb.ApiAuth

  describe "sign_access_token/1 + verify_access_token/1" do
    test "round-trips the user id" do
      user = user_fixture()
      token = ApiAuth.sign_access_token(user)

      assert {:ok, %{user_id: user_id}} = ApiAuth.verify_access_token(token)
      assert user_id == user.id
    end

    test "rejects a tampered token" do
      user = user_fixture()
      token = ApiAuth.sign_access_token(user)

      assert ApiAuth.verify_access_token(token <> "x") == {:error, :invalid}
    end

    test "rejects an expired token" do
      user = user_fixture()

      token =
        Phoenix.Token.sign(TabletapWeb.Endpoint, "api_auth", %{user_id: user.id},
          signed_at: System.system_time(:second) - 1_000_000
        )

      assert ApiAuth.verify_access_token(token) == {:error, :expired}
    end
  end
end

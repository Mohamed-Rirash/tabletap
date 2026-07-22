defmodule TabletapWeb.Api.AuthControllerTest do
  @moduledoc """
  build-plan.md Feature 23 — mobile login. Each `request_magic_link`
  test uses its own `x-forwarded-for` IP (same reasoning as
  `MenuLiveRateLimitTest`, Feature 22): `RateLimiter.check({:auth_email,
  ip})` is a single shared ETS table, and every async test in this
  suite sharing the default loopback IP would otherwise race.
  """
  use TabletapWeb.ConnCase, async: true

  import Tabletap.AccountsFixtures

  alias Tabletap.Accounts
  alias Tabletap.Accounts.UserToken
  alias Tabletap.Repo
  alias TabletapWeb.ApiAuth

  defp with_unique_ip(conn) do
    put_req_header(conn, "x-forwarded-for", "203.0.113.#{System.unique_integer([:positive])}")
  end

  describe "POST /api/v1/auth/request_magic_link" do
    test "sends a magic link email when the user exists", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> with_unique_ip()
        |> post(~p"/api/v1/auth/request_magic_link", %{"email" => user.email})

      assert %{"message" => message} = json_response(conn, 200)
      assert message =~ "If your email is in our system"

      assert Repo.get_by(UserToken, [user_id: user.id, context: "login"], skip_org_id: true)
    end

    test "does not disclose whether the email is registered", %{conn: conn} do
      conn =
        conn
        |> with_unique_ip()
        |> post(~p"/api/v1/auth/request_magic_link", %{"email" => "nobody@example.com"})

      assert %{"message" => message} = json_response(conn, 200)
      assert message =~ "If your email is in our system"
    end
  end

  describe "POST /api/v1/auth/confirm" do
    test "a valid magic-link token exchanges for an access + refresh token pair", %{conn: conn} do
      user = user_fixture()

      token =
        extract_user_token(fn url_fun -> Accounts.deliver_login_instructions(user, url_fun) end)

      conn = post(conn, ~p"/api/v1/auth/confirm", %{"token" => token})

      assert %{
               "access_token" => access_token,
               "refresh_token" => refresh_token,
               "expires_in" => 900,
               "user" => %{"id" => user_id, "email" => email}
             } = json_response(conn, 200)

      assert user_id == user.id
      assert email == user.email
      assert {:ok, %{user_id: ^user_id}} = ApiAuth.verify_access_token(access_token)
      assert {:ok, {_user, _new_token}} = Accounts.exchange_api_refresh_token(refresh_token)
    end

    test "an invalid or expired token is rejected", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/auth/confirm", %{"token" => "not-a-real-token"})

      assert %{"error" => "invalid_or_expired_link"} = json_response(conn, 401)
    end
  end

  describe "POST /api/v1/auth/refresh" do
    test "rotates a valid refresh token for a fresh pair", %{conn: conn} do
      user = user_fixture()
      refresh_token = Accounts.generate_api_refresh_token(user)

      conn = post(conn, ~p"/api/v1/auth/refresh", %{"refresh_token" => refresh_token})

      assert %{"access_token" => access_token, "refresh_token" => new_refresh_token} =
               json_response(conn, 200)

      assert new_refresh_token != refresh_token
      assert {:ok, %{user_id: user_id}} = ApiAuth.verify_access_token(access_token)
      assert user_id == user.id
    end

    test "a stale (already-rotated) refresh token is rejected", %{conn: conn} do
      user = user_fixture()
      refresh_token = Accounts.generate_api_refresh_token(user)
      {:ok, _} = Accounts.exchange_api_refresh_token(refresh_token)

      conn = post(conn, ~p"/api/v1/auth/refresh", %{"refresh_token" => refresh_token})

      assert %{"error" => "invalid_refresh_token"} = json_response(conn, 401)
    end
  end

  describe "POST /api/v1/auth/logout" do
    test "revokes the refresh token", %{conn: conn} do
      user = user_fixture()
      refresh_token = Accounts.generate_api_refresh_token(user)

      conn = post(conn, ~p"/api/v1/auth/logout", %{"refresh_token" => refresh_token})
      assert response(conn, 204)

      assert Accounts.exchange_api_refresh_token(refresh_token) == {:error, :invalid}
    end
  end
end

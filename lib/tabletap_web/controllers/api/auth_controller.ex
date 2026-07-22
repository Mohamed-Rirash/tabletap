defmodule TabletapWeb.Api.AuthController do
  @moduledoc """
  Mobile login (build-plan.md Feature 23) — reuses the exact same
  magic-link mechanism the web login form uses (`Accounts.
  deliver_login_instructions/2`, `Accounts.login_user_by_magic_link/1`),
  just with a `tabletap://auth/:token` deep link instead of a web URL,
  and a JSON token pair instead of a session cookie at the end.
  """
  use TabletapWeb, :controller

  alias Tabletap.Accounts
  alias TabletapWeb.ApiAuth
  alias TabletapWeb.RateLimiter

  @generic_message "If your email is in our system, you will receive instructions for logging in shortly."

  @doc """
  Sends a magic-link login email whose link deep-links back into the
  app. Same per-IP throttle and non-enumeration response as the web
  login form (design-qa.md Q47) — the response is identical whether the
  email exists, doesn't exist, or the send was rate-limited.
  """
  def request_magic_link(conn, %{"email" => email}) do
    ip = RateLimiter.client_ip_from_conn(conn)

    if RateLimiter.check({:auth_email, ip}) == :ok do
      if user = Accounts.get_user_by_email(email) do
        Accounts.deliver_login_instructions(user, &"tabletap://auth/#{&1}")
      end
    end

    json(conn, %{message: @generic_message})
  end

  @doc """
  Exchanges a consumed magic-link token for an access + refresh token
  pair — the mobile equivalent of `UserSessionController.create/2`'s
  magic-link branch, minus the session cookie.
  """
  def confirm(conn, %{"token" => token}) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, _tokens_to_disconnect}} ->
        json(conn, token_response(user))

      {:error, :not_found} ->
        invalid_link(conn)
    end
  end

  @doc "Rotates a refresh token for a fresh access + refresh pair."
  def refresh(conn, %{"refresh_token" => token}) do
    case Accounts.exchange_api_refresh_token(token) do
      {:ok, {user, refresh_token}} ->
        json(conn, token_response(user, refresh_token))

      {:error, :invalid} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "invalid_refresh_token"})
    end
  end

  @doc "Revokes a refresh token (sign out this device)."
  def logout(conn, %{"refresh_token" => token}) do
    :ok = Accounts.revoke_api_refresh_token(token)
    send_resp(conn, :no_content, "")
  end

  defp token_response(user, refresh_token \\ nil) do
    %{
      access_token: ApiAuth.sign_access_token(user),
      expires_in: ApiAuth.access_token_max_age(),
      refresh_token: refresh_token || Accounts.generate_api_refresh_token(user),
      user: %{id: user.id, email: user.email}
    }
  end

  defp invalid_link(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "invalid_or_expired_link"})
  end
end

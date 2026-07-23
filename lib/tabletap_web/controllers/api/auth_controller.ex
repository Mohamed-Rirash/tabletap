defmodule TabletapWeb.Api.AuthController do
  @moduledoc """
  Mobile login (build-plan.md Feature 23) — reuses the exact same
  magic-link mechanism the web login form uses (`Accounts.
  deliver_login_instructions/2`, `Accounts.login_user_by_magic_link/1`),
  just with a `tabletap://auth/:token`-shaped deep link instead of a web
  URL, and a JSON token pair instead of a session cookie at the end.
  """
  use TabletapWeb, :controller

  alias Tabletap.Accounts
  alias TabletapWeb.ApiAuth
  alias TabletapWeb.RateLimiter

  @generic_message "If your email is in our system, you will receive instructions for logging in shortly."

  # build-plan.md Feature 25 — the staff app registers its own URL
  # scheme (`tabletap-staff`), separate from the customer app's
  # `tabletap`, since two installed apps can't both reliably own the
  # same custom scheme on one device. An allowlist, not a raw
  # client-supplied scheme string, since this becomes part of a real
  # email sent to the account holder.
  @schemes %{"customer" => "tabletap", "staff" => "tabletap-staff"}
  @default_app "customer"

  @doc """
  Sends a magic-link login email whose link deep-links back into
  whichever app requested it (`"app"` param: `"customer"` or `"staff"`,
  defaulting to `"customer"` for the existing customer-app call sites
  that don't pass it). Same per-IP throttle and non-enumeration response
  as the web login form (design-qa.md Q47) — the response is identical
  whether the email exists, doesn't exist, or the send was rate-limited.
  """
  def request_magic_link(conn, %{"email" => email} = params) do
    ip = RateLimiter.client_ip_from_conn(conn)
    scheme = Map.get(@schemes, params["app"], @schemes[@default_app])

    if RateLimiter.check({:auth_email, ip}) == :ok do
      if user = Accounts.get_user_by_email(email) do
        Accounts.deliver_login_instructions(user, &"#{scheme}://auth/#{&1}")
      end
    end

    json(conn, %{message: @generic_message})
  end

  @doc """
  Email + password login — the mobile equivalent of `UserSessionController.
  create/2`'s password branch. build-plan.md Feature 25: design-qa.md
  Q47 requires owner/manager accounts to carry a password specifically
  so an email delay can never lock a venue out of its own dashboard;
  without this endpoint that same escape hatch didn't exist on the
  mobile staff app. Same non-enumeration framing as the web form and
  `request_magic_link/2` above — a wrong email and a wrong password for
  a real email get an identical response.
  """
  def login(conn, %{"email" => email, "password" => password}) do
    if user = Accounts.get_user_by_email_and_password(email, password) do
      json(conn, token_response(user))
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "invalid_email_or_password"})
    end
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

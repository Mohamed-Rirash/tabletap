defmodule TabletapWeb.ApiAuth do
  @moduledoc """
  Bearer-token auth for `/api/v1` (build-plan.md Feature 23). The access
  token is a short-lived, stateless `Phoenix.Token` (fast to verify, no
  DB round trip on every request); the longer-lived refresh token is
  DB-backed (`Tabletap.Accounts.UserToken`, context `"api_refresh"`) so
  it can actually be revoked — see `Accounts.exchange_api_refresh_token/1`
  and `revoke_api_refresh_token/1`.

  Deliberately separate from `TabletapWeb.UserAuth` (session-cookie web
  auth) rather than unified with it — a bearer token has no session/CSRF
  concept, and mixing the two auth mechanisms into one plug would make
  both harder to reason about.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Tabletap.Accounts

  @salt "api_auth"
  @access_token_max_age_seconds 900

  @doc "Mints a short-lived access token for `user`."
  def sign_access_token(user) do
    Phoenix.Token.sign(TabletapWeb.Endpoint, @salt, %{user_id: user.id})
  end

  @doc "How long a freshly minted access token is valid for, in seconds."
  def access_token_max_age, do: @access_token_max_age_seconds

  @doc """
  Verifies a raw access token. Returns `{:ok, user_id}` or
  `{:error, :expired | :invalid | :missing}`.
  """
  def verify_access_token(token) do
    Phoenix.Token.verify(TabletapWeb.Endpoint, @salt, token,
      max_age: @access_token_max_age_seconds
    )
  end

  @doc """
  Plug: resolves the `Authorization: Bearer <token>` header into
  `conn.assigns.current_api_user` (a `%Tabletap.Accounts.User{}` or
  `nil`). Never halts — routes that require auth pair this with
  `require_authenticated_api_user/2`, so a route that's fine with an
  anonymous caller (none currently, but the pattern matches
  `fetch_current_scope_for_user`'s own separation of "resolve" from
  "enforce") isn't forced to reject one.
  """
  def fetch_bearer_user(conn, _opts) do
    with [header] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- header,
         {:ok, %{user_id: user_id}} <- verify_access_token(token),
         %Accounts.User{} = user <- Accounts.get_user(user_id) do
      assign(conn, :current_api_user, user)
    else
      _ -> assign(conn, :current_api_user, nil)
    end
  end

  @doc "Plug: 401s unless `fetch_bearer_user/2` already resolved a user."
  def require_authenticated_api_user(conn, _opts) do
    if conn.assigns[:current_api_user] do
      conn
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "missing_or_invalid_token"})
      |> halt()
    end
  end
end

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

  alias Tabletap.{Accounts, Tenants}

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

  @doc """
  Plug: builds `conn.assigns.current_scope` from the already-resolved
  `current_api_user` — same `Tenants.build_scope/2` the web session uses,
  just fed an explicit `membership_id` query/body param instead of a
  session map (mirrors the web's own `POST /venues/switch`: a user
  holding more than one membership picks one; absent, the same "first
  active membership" default `build_scope/2` already falls back to).
  Only meaningful after `require_authenticated_api_user/2`.
  """
  def assign_scope(conn, _opts) do
    scope =
      Tenants.build_scope(conn.assigns.current_api_user, %{
        "current_membership_id" => conn.params["membership_id"]
      })

    assign(conn, :current_scope, scope)
  end

  @doc """
  Plug-with-opts: 403s unless `current_scope.role` is in the given list.
  Mirrors `TabletapWeb.ScopeHooks`' role gates for LiveViews, applied to
  a bearer-token request instead of a socket mount.
  """
  def require_api_role(conn, allowed_roles) do
    if conn.assigns.current_scope.role in allowed_roles do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "forbidden"})
      |> halt()
    end
  end
end

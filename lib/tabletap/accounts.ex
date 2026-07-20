defmodule Tabletap.Accounts do
  @moduledoc """
  The Accounts context.

  `users` (and `user_tokens`) are **not** tenant-owned — customer identity
  and login are platform-level, and org/venue membership is layered on top
  by `Tabletap.Tenants` (architecture.md "Multi-Tenancy": "Customer data is
  NOT tenant-owned"). Every query in this module therefore passes
  `skip_org_id: true` explicitly — one of the few contexts allowed to
  (code-standards.md "Tenancy Rules").
  """

  import Ecto.Query, warn: false
  alias Tabletap.Repo
  alias Tabletap.Tenants

  alias Tabletap.Accounts.{User, UserNotifier, UserToken}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, [email: email], skip_org_id: true)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, [email: email], skip_org_id: true)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id, skip_org_id: true)

  @doc """
  GDPR customer account deletion (build-plan.md Feature 19;
  design-qa.md Q15: "account + PII erased; orders anonymized
  (customer_user_id nulled, guest linkage severed) but retained;
  ratings kept aggregate-only; push tokens purged"). Deleting the
  `User` row is the entire mechanism — `orders.customer_user_id` and
  `item_ratings.customer_user_id` both already carry `on_delete:
  :nilify_all` (their own migrations anticipated exactly this), so
  order/rating history survives, severed from the identity that
  created it, with no extra code needed here. Push-token purge is a
  no-op today — no `push_tokens` table exists yet (Feature 20's web
  push hasn't landed).

  Refuses to delete an account holding any staff membership —
  `memberships.user_id` is `on_delete: :delete_all`, so cascading
  through it would silently orphan a venue's staff or, worse, its
  owner. This is customer self-deletion (Q15's own framing: "a
  customer demands deletion"), not a staff offboarding flow.
  """
  def delete_account(%User{} = user) do
    if Tenants.any_memberships?(user.id) do
      {:error, :has_staff_membership}
    else
      Repo.delete(user)
    end
  end

  ## User registration

  @doc """
  Registers a user via the magic-link-first path (customers; waiter/cashier/
  kitchen staff via invite acceptance). No password — see
  `register_owner/1` for the owner/manager path, which requires one
  (design-qa.md Q47).

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Registers a user with a required password and confirms the account
  immediately — the owner/manager path (design-qa.md Q47). Used by
  `Tabletap.Tenants.create_org_with_owner/1`; not tenant-scoped itself
  since the org doesn't exist yet at this point.

  ## Examples

      iex> register_owner(%{email: "a@b.com", password: "..." , password_confirmation: "..."})
      {:ok, %User{}}

      iex> register_owner(%{email: "bad", password: "short"})
      {:error, %Ecto.Changeset{}}

  """
  def register_owner(attrs) do
    %User{}
    |> User.owner_registration_changeset(attrs)
    |> Repo.insert()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Tabletap.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query, skip_org_id: true),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context]),
               skip_org_id: true
             ) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Tabletap.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query, skip_org_id: true)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query, skip_org_id: true) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query, skip_org_id: true) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  # Per-email magic-link resend cooldown (design-qa.md Q47) — independent
  # of TabletapWeb.RateLimiter's per-IP check, which lives at the web layer.
  @magic_link_resend_cooldown_seconds 60

  @doc """
  Delivers the magic link login instructions to the given user.

  Throttled to at most one send per #{@magic_link_resend_cooldown_seconds}s
  per user — a repeat call inside the cooldown returns `{:ok, :throttled}`
  without sending another email or minting another token, so callers can
  still show the same generic success message either way.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    if Repo.exists?(UserToken.recent_login_token_query(user, @magic_link_resend_cooldown_seconds),
         skip_org_id: true
       ) do
      {:ok, :throttled}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "login")
      Repo.insert!(user_token)
      UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
    end
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]),
      skip_org_id: true
    )

    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, [user_id: user.id], skip_org_id: true)

        Repo.delete_all(
          from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)),
          skip_org_id: true
        )

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end

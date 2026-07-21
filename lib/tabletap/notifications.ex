defmodule Tabletap.Notifications do
  @moduledoc """
  Web Push (build-plan.md Feature 20; architecture.md's own
  "notifications/ → Web push subscriptions, notification fan-out").
  Not tenant-owned (see `PushSubscription`'s own moduledoc) — every
  query here passes `skip_org_id: true`, the same reasoning
  `Tabletap.Accounts` already documents for `users`/`user_tokens`: a
  subscription belongs to a person, and a person can hold memberships
  (and receive pushes) across more than one org.

  `send_push/2` does a real HTTP POST and never runs inline in a
  request process — `Notifications.Workers.SendPush` (Feature 20
  Commit 2) is the only real caller; call it directly only from tests
  or that worker.
  """

  import Ecto.Query, warn: false

  alias Tabletap.Accounts.User
  alias Tabletap.Notifications.PushSubscription
  alias Tabletap.Repo

  @doc "The VAPID public key, handed to the browser as `pushManager.subscribe/1`'s `applicationServerKey` — safe to render straight into a page (see `config.exs`'s own comment: it's not secret)."
  def vapid_public_key do
    Application.fetch_env!(:web_push_ex, :vapid) |> Keyword.fetch!(:public_key)
  end

  @doc """
  Registers a browser's Web Push subscription for `user` — idempotent:
  re-subscribing the same device (a token refresh, a re-granted
  permission) updates the existing row rather than creating a second
  one, via the `(user_id, endpoint)` unique index.
  """
  def subscribe(%User{} = user, attrs) do
    %PushSubscription{}
    |> PushSubscription.changeset(Map.put(attrs, "user_id", user.id))
    |> Repo.insert(
      on_conflict: {:replace, [:p256dh, :auth, :user_agent, :updated_at]},
      conflict_target: [:user_id, :endpoint],
      # Without this, Ecto trusts the client-generated `id` it already
      # has on the (unsaved) struct instead of reading back which row
      # the upsert actually touched — on a conflict, that's the
      # *existing* row's id, not the one just discarded. Confirmed by
      # a failing test before this was added.
      returning: true
    )
  end

  @doc "Removes one browser's subscription (the user turned notifications off, or the endpoint the browser reports has rotated)."
  def unsubscribe(%User{} = user, endpoint) do
    Repo.delete_all(
      from(s in PushSubscription, where: s.user_id == ^user.id and s.endpoint == ^endpoint),
      skip_org_id: true
    )

    :ok
  end

  @doc "Every subscription for `user_id` — usually more than one (a phone and a desktop, say)."
  def list_subscriptions_for_user(user_id) do
    Repo.all(from(s in PushSubscription, where: s.user_id == ^user_id), skip_org_id: true)
  end

  @doc "Sends `payload` (a plain map — `%{title:, body:, url:}`, read by the service worker's own `showNotification` call) to every subscription `user_id` has."
  def notify_user(user_id, payload) when is_map(payload) do
    user_id
    |> list_subscriptions_for_user()
    |> Enum.each(&send_push(&1, payload))
  end

  @doc """
  One push, one subscription. A `404`/`410` response means the
  browser has permanently unsubscribed (uninstalled, revoked
  permission, cleared storage) — the standard Web Push signal to stop
  sending, so the subscription row is deleted rather than retried.
  Any other outcome (success, a transient 5xx, a network error) is
  left alone — the next real event is the natural retry, not a
  scheduled one.
  """
  def send_push(%PushSubscription{} = subscription, payload) when is_map(payload) do
    ws_subscription = %WebPushEx.Subscription{
      endpoint: URI.parse(subscription.endpoint),
      keys: %{p256dh: subscription.p256dh, auth: subscription.auth}
    }

    request = WebPushEx.request(ws_subscription, Jason.encode!(payload))
    req_opts = Application.get_env(:tabletap, :web_push_req_options, [])

    request.endpoint
    |> URI.to_string()
    |> Req.post([body: request.body, headers: request.headers] ++ req_opts)
    |> handle_response(subscription)
  end

  defp handle_response({:ok, %Req.Response{status: status}}, subscription)
       when status in [404, 410] do
    Repo.delete(subscription)
    :ok
  end

  defp handle_response(_result, _subscription), do: :ok
end

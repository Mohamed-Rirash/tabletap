defmodule TabletapWeb.ApiSocket do
  @moduledoc """
  Mobile realtime transport (build-plan.md Feature 23 Commit 3) — the
  official `phoenix` npm client connects here. Every channel just
  relays PubSub broadcasts the web app's own LiveViews already receive
  (the exact topics named in architecture.md: `order:{id}`,
  `waiter:{membership_id}`, `venue:{id}:claim_board`,
  `venue:{id}:orders`) — no new domain events.

  An optional bearer `token` connect param resolves
  `socket.assigns.current_user` for the staff channels
  (`WaiterChannel`/`VenueChannel`), which need it to authorize a join.
  The customer-facing `OrderChannel` needs no socket-level auth at all
  — same guest-token-based design as the REST customer API — so a
  missing token still connects successfully; only a *present but
  invalid* token is rejected outright (an app that thinks it's signed
  in should never silently downgrade to anonymous).
  """
  use Phoenix.Socket

  alias Tabletap.Accounts
  alias TabletapWeb.ApiAuth

  channel "order:*", TabletapWeb.OrderChannel
  channel "waiter:*", TabletapWeb.WaiterChannel
  channel "venue:*", TabletapWeb.VenueChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    with {:ok, %{user_id: user_id}} <- ApiAuth.verify_access_token(token),
         %Accounts.User{} = user <- Accounts.get_user(user_id) do
      {:ok, assign(socket, :current_user, user)}
    else
      _ -> :error
    end
  end

  def connect(_params, socket, _connect_info), do: {:ok, assign(socket, :current_user, nil)}

  @impl true
  def id(%{assigns: %{current_user: %Accounts.User{id: id}}}), do: "api_user:#{id}"
  def id(_socket), do: nil
end

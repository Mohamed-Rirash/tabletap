defmodule TabletapWeb.ScopeHooks do
  @moduledoc """
  Role enforcement for LiveViews, via `on_mount` — never scattered
  `if role == :manager` checks inside individual `handle_event`s
  (code-standards.md). Each named hook is a thin wrapper around the
  shared `require_role/2` primitive (build-plan.md Feature 02).

  `scope.role` comes from `Tabletap.Tenants.build_scope/2` (Feature 03) —
  `nil` for a logged-in user with no staff membership, which correctly
  denies every one of these hooks (deny-by-default, not a temporary hole).
  """
  use TabletapWeb, :verified_routes

  import Phoenix.LiveView

  def on_mount(:require_waiter, _params, _session, socket),
    do: require_role(socket, [:waiter])

  def on_mount(:require_kitchen, _params, _session, socket),
    do: require_role(socket, [:kitchen])

  def on_mount(:require_cashier, _params, _session, socket),
    do: require_role(socket, [:cashier])

  # Owners can do everything a manager can, plus more (role-features.md) —
  # manager-gated pages always admit owners too.
  def on_mount(:require_manager, _params, _session, socket),
    do: require_role(socket, [:manager, :owner])

  def on_mount(:require_owner, _params, _session, socket),
    do: require_role(socket, [:owner])

  @doc """
  Halts and redirects unless the current scope's role is one of `roles`.
  """
  def require_role(socket, roles) when is_list(roles) do
    scope = socket.assigns[:current_scope]

    if scope && scope.role in roles do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, "You don't have access to that page.")
       |> redirect(to: ~p"/")}
    end
  end
end

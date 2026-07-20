defmodule TabletapWeb.AdminAuth do
  @moduledoc """
  Platform-admin gate for the `/admin` LiveViews (build-plan.md
  Feature 19; role-features.md "Platform Admin (us) — us only, no
  self-serve"). Distinct from `ScopeHooks`: an admin isn't a member of
  any tenant, so there's no `scope.role` to check — this looks at
  `current_scope.user.platform_admin` directly. Always runs after
  `{TabletapWeb.UserAuth, :require_authenticated}`, same ordering
  convention every other role/plan gate in this app follows.
  """
  use TabletapWeb, :verified_routes

  import Phoenix.LiveView

  def on_mount(:require_platform_admin, _params, _session, socket) do
    scope = socket.assigns[:current_scope]

    if scope && scope.user && scope.user.platform_admin do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, "You don't have access to that page.")
       |> redirect(to: ~p"/")}
    end
  end
end

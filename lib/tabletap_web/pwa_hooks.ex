defmodule TabletapWeb.PwaHooks do
  @moduledoc """
  Assigns `:pwa_manifest` via `on_mount` (build-plan.md Feature 20 — "PWA
  manifests per surface (customer/waiter)") so `root.html.heex` can link
  the right `<link rel="manifest">` and render the install-prompt button
  without every LiveView threading the assign through by hand. Only the
  two installable surfaces get one — `Manager.DashboardLive` and the rest
  of the back office stay a plain browser tab, per the plan's own scope.
  """
  import Phoenix.Component, only: [assign: 3]

  def on_mount(:customer, _params, _session, socket),
    do: {:cont, assign(socket, :pwa_manifest, "customer")}

  def on_mount(:waiter, _params, _session, socket),
    do: {:cont, assign(socket, :pwa_manifest, "waiter")}
end

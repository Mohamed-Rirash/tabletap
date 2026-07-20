defmodule TabletapWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use TabletapWeb, :html

  alias Tabletap.Plans

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar border-b border-base-300/60 px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex w-fit items-center gap-2">
          <span class="grid h-8 w-8 place-items-center rounded-field bg-primary text-primary-content text-sm font-bold">
            T
          </span>
          <span class="text-sm font-semibold">TableTap</span>
        </a>
      </div>
      <div class="flex-none">
        <.theme_toggle />
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Full-bleed dark shell for the KDS (`/kitchen`) — ui-tokens.md "KDS:
  always dark — kitchen tablets run for 12h and glare matters". The
  `data-theme="dark"` wrapper pins daisyUI's dark tokens for the whole
  subtree regardless of the device's theme preference (same forced-look
  reasoning as the marketing page's `.mk` scope). No header/nav chrome
  of its own: the board owns every pixel; the caller must also
  `assign(:hide_utility_bar, true)`.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  slot :inner_block, required: true

  def kds(assigns) do
    ~H"""
    <div data-theme="dark" class="min-h-dvh bg-base-200 text-base-content">
      {render_slot(@inner_block)}
      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Sidebar shell for manager/owner pages (`/dashboard`, `/menu`, ...) —
  venue switcher, primary nav, user/log-out, in place of `Layouts.app`'s
  plain header (never both: the caller must also `assign(:hide_utility_bar,
  true)` so root.html.heex's sitewide utility bar doesn't render a second,
  competing set of Settings/Log out links).

  Kitchen links out to the KDS (`/kitchen`) — it renders its own dark
  full-bleed shell (`Layouts.kds/1`), not this sidebar.

  ## Examples

      <Layouts.manager flash={@flash} current_scope={@current_scope} active_nav={:menu} venues={@venues}>
        <h1>Content</h1>
      </Layouts.manager>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, required: true

  attr :active_nav, :atom,
    required: true,
    doc:
      ":dashboard, :orders, :menu, :modifiers, :tables, :inventory, :feedback, :analytics_reports, :analytics_revenue, :analytics_menu_performance, :analytics_customers, :analytics_staff, :analytics_inventory_cost, :analytics_org, or :payments"

  attr :venues, :list, default: []

  slot :inner_block, required: true

  def manager(assigns) do
    ~H"""
    <div class="flex min-h-screen">
      <aside class="hidden lg:flex lg:w-64 lg:shrink-0 lg:flex-col border-r border-base-300 bg-base-100">
        <div class="p-4 border-b border-base-300">
          <a href="/" class="flex items-center gap-2">
            <span class="grid h-8 w-8 place-items-center rounded-field bg-primary text-primary-content text-sm font-bold">
              T
            </span>
            <span class="text-sm font-semibold">TableTap</span>
          </a>
        </div>

        <div class="p-4 border-b border-base-300">
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50 mb-1">
            {gettext("Venue")}
          </p>
          <.form
            :if={length(@venues) > 1}
            for={%{}}
            as={:venue}
            method="post"
            action={~p"/venues/switch"}
          >
            <select
              name="venue_id"
              class="select select-sm w-full"
              onchange="this.form.requestSubmit()"
            >
              <option
                :for={venue <- @venues}
                value={venue.id}
                selected={venue.id == @current_scope.venue.id}
              >
                {venue.name}
              </option>
            </select>
          </.form>
          <p :if={length(@venues) <= 1} class="text-sm font-medium truncate">
            {@current_scope.venue.name}
          </p>
        </div>

        <nav class="flex-1 overflow-y-auto p-3 space-y-1">
          <p class="px-2 text-xs font-semibold uppercase tracking-wide text-base-content/50 mb-1">
            {gettext("Menu")}
          </p>
          <.manager_nav_link
            navigate={~p"/dashboard"}
            icon="hero-squares-2x2"
            active={@active_nav == :dashboard}
          >
            {gettext("Dashboard")}
          </.manager_nav_link>
          <.manager_nav_link
            navigate={~p"/orders"}
            icon="hero-clipboard-document-list"
            active={@active_nav == :orders}
          >
            {gettext("Orders")}
          </.manager_nav_link>
          <.manager_nav_link
            navigate={~p"/tables"}
            icon="hero-table-cells"
            active={@active_nav == :tables}
          >
            {gettext("Tables")}
          </.manager_nav_link>
          <.manager_nav_link navigate={~p"/kitchen"} icon="hero-fire" active={false}>
            {gettext("Kitchen")}
          </.manager_nav_link>
          <.manager_nav_link navigate={~p"/menu"} icon="hero-book-open" active={@active_nav == :menu}>
            {gettext("Menu")}
          </.manager_nav_link>
          <.manager_nav_link
            navigate={~p"/menu/modifiers"}
            icon="hero-adjustments-horizontal"
            active={@active_nav == :modifiers}
          >
            {gettext("Modifiers")}
          </.manager_nav_link>
          <.manager_nav_link
            :if={Plans.feature_enabled?(@current_scope.org, :inventory)}
            navigate={~p"/inventory"}
            icon="hero-cube"
            active={@active_nav == :inventory}
          >
            {gettext("Inventory")}
          </.manager_nav_link>
          <.manager_nav_link navigate={~p"/pos"} icon="hero-calculator" active={false}>
            {gettext("POS")}
          </.manager_nav_link>
          <.manager_nav_link
            navigate={~p"/feedback"}
            icon="hero-chat-bubble-left-right"
            active={@active_nav == :feedback}
          >
            {gettext("Feedback")}
          </.manager_nav_link>
          <.manager_nav_link
            navigate={~p"/reports"}
            icon="hero-document-chart-bar"
            active={@active_nav == :analytics_reports}
          >
            {gettext("Reports")}
          </.manager_nav_link>
          <.manager_nav_link
            navigate={~p"/analytics/revenue"}
            icon="hero-chart-bar"
            active={@active_nav == :analytics_revenue}
          >
            {gettext("Revenue & Sales")}
          </.manager_nav_link>
          <.manager_nav_link
            navigate={~p"/analytics/menu-performance"}
            icon="hero-squares-plus"
            active={@active_nav == :analytics_menu_performance}
          >
            {gettext("Menu Performance")}
          </.manager_nav_link>
          <.manager_nav_link
            navigate={~p"/analytics/customers"}
            icon="hero-user-group"
            active={@active_nav == :analytics_customers}
          >
            {gettext("Customers")}
          </.manager_nav_link>
          <.manager_nav_link
            navigate={~p"/analytics/staff"}
            icon="hero-users"
            active={@active_nav == :analytics_staff}
          >
            {gettext("Staff & Work")}
          </.manager_nav_link>
          <.manager_nav_link
            navigate={~p"/analytics/inventory-cost"}
            icon="hero-archive-box"
            active={@active_nav == :analytics_inventory_cost}
          >
            {gettext("Inventory & Cost")}
          </.manager_nav_link>
          <.manager_nav_link
            :if={@current_scope.role == :owner}
            navigate={~p"/analytics/venues"}
            icon="hero-building-storefront"
            active={@active_nav == :analytics_org}
          >
            {gettext("Org View")}
          </.manager_nav_link>

          <p class="px-2 text-xs font-semibold uppercase tracking-wide text-base-content/50 mt-4 mb-1">
            {gettext("Others")}
          </p>
          <.manager_nav_link
            :if={@current_scope.role == :owner}
            navigate={~p"/settings/payments"}
            icon="hero-credit-card"
            active={@active_nav == :payments}
          >
            {gettext("Payment account")}
          </.manager_nav_link>
          <.manager_nav_link navigate={~p"/users/settings"} icon="hero-cog-6-tooth" active={false}>
            {gettext("Settings")}
          </.manager_nav_link>
        </nav>

        <div class="p-3 border-t border-base-300 flex items-center gap-2">
          <span class="grid h-8 w-8 place-items-center rounded-full bg-base-300 text-xs font-semibold shrink-0">
            {@current_scope.user.email |> String.first() |> String.upcase()}
          </span>
          <div class="flex-1 min-w-0">
            <p class="text-sm font-medium truncate">{@current_scope.user.email}</p>
            <p class="text-xs text-base-content/50">{manager_role_label(@current_scope.role)}</p>
          </div>
          <.link
            href={~p"/users/log-out"}
            method="delete"
            class="text-base-content/50 hover:text-base-content shrink-0"
            title={gettext("Log out")}
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" />
          </.link>
        </div>
      </aside>

      <div class="flex-1 min-w-0 flex flex-col">
        <div class="flex-none flex items-center justify-between gap-3 border-b border-base-300/60 px-4 py-2 lg:justify-end">
          <div class="flex items-center gap-3 lg:hidden">
            <.link navigate={~p"/dashboard"} class={@active_nav == :dashboard && "font-semibold"}>
              {gettext("Dashboard")}
            </.link>
            <.link navigate={~p"/orders"} class={@active_nav == :orders && "font-semibold"}>
              {gettext("Orders")}
            </.link>
            <.link navigate={~p"/menu"} class={@active_nav == :menu && "font-semibold"}>
              {gettext("Menu")}
            </.link>
            <.link navigate={~p"/menu/modifiers"} class={@active_nav == :modifiers && "font-semibold"}>
              {gettext("Modifiers")}
            </.link>
            <.link navigate={~p"/tables"} class={@active_nav == :tables && "font-semibold"}>
              {gettext("Tables")}
            </.link>
            <.link
              :if={Plans.feature_enabled?(@current_scope.org, :inventory)}
              navigate={~p"/inventory"}
              class={@active_nav == :inventory && "font-semibold"}
            >
              {gettext("Inventory")}
            </.link>
            <.link navigate={~p"/kitchen"}>
              {gettext("Kitchen")}
            </.link>
            <.link navigate={~p"/pos"}>
              {gettext("POS")}
            </.link>
            <.link navigate={~p"/feedback"} class={@active_nav == :feedback && "font-semibold"}>
              {gettext("Feedback")}
            </.link>
          </div>
          <.theme_toggle />
        </div>
        <main class="flex-1 overflow-y-auto bg-base-200 px-4 py-6 sm:px-6 lg:px-8">
          <div class="mx-auto max-w-5xl">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp manager_nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex items-center gap-2 rounded-field px-3 py-2 text-sm font-medium transition-colors",
        @active && "bg-primary text-primary-content",
        !@active && "text-base-content/70 hover:bg-base-200"
      ]}
    >
      <.icon name={@icon} class="size-4 shrink-0" /> {render_slot(@inner_block)}
    </.link>
    """
  end

  defp manager_role_label(:owner), do: gettext("Owner")
  defp manager_role_label(:manager), do: gettext("Manager")
  defp manager_role_label(role), do: to_string(role)

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end

defmodule TabletapWeb.Public.MenuLive do
  @moduledoc """
  Read-only public menu — no auth (library-docs.md "Customer/public paths
  build an unauthenticated scope from the QR-resolved venue"). Temporary
  entry point at `/venues/:slug/menu` for Feature 04's verify step;
  Feature 06 fronts this same LiveView with real `/t/:qr_token` → table
  resolution instead of building a second one.

  Updates instantly when a manager changes availability — subscribes to
  `"venue:<id>:menu"`, broadcast by every `TabletapWeb.Manager.MenuLive`
  mutation.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Repo, Tenants}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">{@venue.name}</h1>
      </div>

      <div class="space-y-8">
        <div :for={{category, items} <- @menu} id={"category-#{category.id}"}>
          <h2 class="font-semibold text-lg mb-3">{category.name}</h2>

          <div class="divide-y divide-base-300">
            <div :for={item <- items} id={"item-#{item.id}"} class="flex items-center gap-4 py-3">
              <img
                :if={item.photo_url}
                src={item.photo_url}
                class="size-14 rounded-field object-cover shrink-0"
              />
              <div
                :if={!item.photo_url}
                class="size-14 rounded-field bg-base-200 grid place-items-center shrink-0"
              >
                <.icon name="hero-photo" class="size-6 opacity-40" />
              </div>

              <div class="flex-1 min-w-0">
                <p class="font-medium">{item.name}</p>
                <p :if={item.description} class="text-sm text-base-content/60">{item.description}</p>
                <div class="flex gap-1 mt-1 flex-wrap">
                  <span :for={tag <- item.dietary_tags} class="badge badge-outline badge-xs">
                    {tag}
                  </span>
                </div>
              </div>

              <.money
                amount={item.price}
                locale={@venue.locale}
                class="font-semibold whitespace-nowrap"
              />
            </div>
          </div>
        </div>

        <p :if={@menu == []} class="text-sm text-base-content/50">
          {gettext("This menu is empty right now.")}
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Tenants.get_venue_by_slug(slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Venue not found."))
         |> redirect(to: ~p"/")}

      venue ->
        Repo.put_org_id(venue.org_id)
        scope = %Scope{org: venue.org, venue: venue, role: :guest}

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{venue.id}:menu")
        end

        {:ok,
         socket
         |> assign(:venue, venue)
         |> assign(:current_scope, scope)
         |> assign(:menu, Catalog.list_public_menu(scope))}
    end
  end

  @impl true
  def handle_info(:menu_updated, socket) do
    {:noreply, assign(socket, :menu, Catalog.list_public_menu(socket.assigns.current_scope))}
  end
end

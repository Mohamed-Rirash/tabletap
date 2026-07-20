defmodule TabletapWeb.Public.MenuLive do
  @moduledoc """
  The public menu, item customization, and cart — no auth
  (library-docs.md "Customer/public paths build an unauthenticated scope
  from the QR-resolved venue"). Reached directly at `/venues/:slug/menu`,
  or via a scanned table QR: the `/t/:qr_token` controller stashes the
  resolved `table_id` in the session and redirects here.

  One LiveView, three states via `@overlay` (`:none`, `{:item, item,
  groups}`, `:cart`) — matches how `Manager.MenuLive` already layers an
  item-edit modal over its own page rather than routing to a second
  LiveView; the item detail sheet and cart sheet are both genuinely
  overlays per ui-tokens.md ("bottom sheet"), not separate screens.

  The cart itself is DB-backed (`Tabletap.Ordering`) and rebuilt from
  there on every mount, so reconnects and deploys never lose it
  (design-qa.md Q50). `guest_token` is minted lazily on the *first*
  add-to-cart (architecture.md), not on page load — `TabletapWeb.GuestToken`
  restores a *returning* guest's cookie into the session before mount,
  but writing a *freshly minted* one back to the browser has to happen
  from inside a connected `handle_event` (no HTTP response exists there
  to attach a `Set-Cookie` header to), so it's done via `push_event/3` +
  a colocated hook that sets `document.cookie` directly.

  Updates instantly when a manager changes availability — subscribes to
  `"venue:<id>:menu"`, broadcast by every `TabletapWeb.Manager.MenuLive`
  mutation.
  """
  use TabletapWeb, :live_view

  require Logger

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Feedback, Ordering, Payments, Repo, Tenants}
  alias Tabletap.Ordering.{Cart, CartItem}
  alias Tabletap.Tenants.Venue
  alias TabletapWeb.GuestToken

  @impl true
  @doc """
  design-qa.md Q29: a canceled org's QR menu shows "temporarily
  unavailable" (same wording a trial that expired with no payment
  converts straight to, `Billing.expire_unpaid_trial/1`) — a dedicated
  render clause, not just another `@ordering_status` banner over a
  still-browsable menu like `:paused`/`:closed`, since ordering itself
  is genuinely off, not just degraded.
  """
  def render(%{ordering_status: :unavailable} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mb-4">
        <h1 class="text-2xl font-bold">{@venue.name}</h1>
      </div>
      <div class="rounded-box bg-warning/10 border border-warning/30 px-4 py-6 text-center text-base-content text-sm font-medium">
        {gettext("Ordering is temporarily unavailable. Please check with the venue directly.")}
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="guest-token-carrier" phx-hook=".GuestToken"></div>

      <div class="mb-4">
        <h1 class="text-2xl font-bold">{@venue.name}</h1>
        <p :if={@table} class="mt-1 text-sm font-medium text-base-content/70">
          {gettext("Table %{number}", number: @table.number)}
        </p>
      </div>

      <.link
        :if={@active_order}
        navigate={~p"/orders/#{@active_order.guest_token}"}
        class="mb-4 flex items-center justify-between gap-2 rounded-box bg-brand/10 border border-brand/30 px-4 py-3 text-brand font-medium"
      >
        {gettext("You have an active order →")}
      </.link>

      <div
        :if={@ordering_status != :open}
        class="mb-4 rounded-box bg-warning/10 border border-warning/30 px-4 py-3 text-base-content text-sm font-medium"
      >
        {ordering_status_message(@ordering_status)}
      </div>

      <.category_tabs menu={@menu} />

      <div class="space-y-8 pb-28">
        <div :for={{category, items} <- @menu} id={"category-#{category.id}"} class="scroll-mt-20">
          <h2 class="font-semibold text-lg mb-3">{category.name}</h2>

          <div class="grid gap-3">
            <.item_card
              :for={item <- items}
              item={item}
              remaining={remaining_for(item, @daily_limits)}
              locale={@venue.locale}
              rating={Map.get(@ratings_summary, item.id)}
            />
          </div>
        </div>

        <p :if={@menu == []} class="text-sm text-base-content/50">
          {gettext("This menu is empty right now.")}
        </p>
      </div>

      <.sticky_cart_bar
        :if={@cart && @cart.items != []}
        cart={@cart}
        scope={@current_scope}
        locale={@venue.locale}
      />

      <.item_detail_sheet
        :if={match?({:item, _item, _groups}, @overlay)}
        item={elem(@overlay, 1)}
        groups={elem(@overlay, 2)}
        selected_option_ids={@selected_option_ids}
        qty={@detail_qty}
        submit_attempted={@detail_submit_attempted}
        locale={@venue.locale}
      />

      <.cart_sheet
        :if={@overlay == :cart && @cart}
        cart={@cart}
        scope={@current_scope}
        locale={@venue.locale}
        checkout_error={@checkout_error}
        charges_enabled={@venue.charges_enabled}
        pay_at_counter_enabled={@venue.pay_at_counter_enabled}
        payment_method={@payment_method}
      />

      <script :type={Phoenix.LiveView.ColocatedHook} name=".GuestToken">
        export default {
          mounted() {
            this.handleEvent("persist_guest_token", ({token, max_age}) => {
              document.cookie = `guest_token=${token}; max-age=${max_age}; path=/; samesite=lax`
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end

  ## Function components

  attr :menu, :list, required: true

  defp category_tabs(assigns) do
    ~H"""
    <div
      :if={length(@menu) > 1}
      class="sticky top-0 z-10 -mx-4 sm:-mx-6 lg:-mx-8 px-4 sm:px-6 lg:px-8 py-2 mb-4 bg-base-100/95 backdrop-blur border-b border-base-300 overflow-x-auto"
    >
      <div class="flex gap-2 w-max">
        <a
          :for={{category, _items} <- @menu}
          href={"#category-#{category.id}"}
          class="btn btn-sm btn-ghost whitespace-nowrap"
        >
          {category.name}
        </a>
      </div>
    </div>
    """
  end

  attr :item, Catalog.MenuItem, required: true
  attr :remaining, :any, required: true, doc: ":unlimited | integer"
  attr :locale, :string, required: true

  attr :rating, :any,
    default: nil,
    doc: "%{avg: Decimal, count: integer} | nil — nil renders nothing (build-plan.md Feature 17)"

  defp item_card(assigns) do
    sold_out = assigns.remaining != :unlimited and assigns.remaining <= 0
    assigns = assign(assigns, :sold_out, sold_out)

    ~H"""
    <div
      id={"item-#{@item.id}"}
      phx-click={!@sold_out && "open_item"}
      phx-value-id={@item.id}
      class={[
        "flex items-center gap-3 p-4 rounded-box bg-base-100 border border-base-300",
        !@sold_out && "cursor-pointer",
        @sold_out && "opacity-75"
      ]}
    >
      <div class="flex-1 min-w-0">
        <p class="font-semibold">{@item.name}</p>
        <p :if={@rating} class="text-xs text-base-content/60 flex items-center gap-1">
          <.icon name="hero-star-solid" class="size-3.5 text-warning" />
          {format_avg_stars(@rating.avg)} <span class="text-base-content/40">({@rating.count})</span>
        </p>
        <p :if={@item.description} class="text-sm text-base-content/60 line-clamp-2">
          {@item.description}
        </p>
        <div class="flex items-center gap-1.5 mt-1 flex-wrap">
          <span
            :for={tag <- @item.dietary_tags}
            class="badge badge-sm bg-base-300 border-none text-[11px]"
          >
            {tag}
          </span>
          <span
            :for={tag <- @item.allergen_tags}
            class="badge badge-sm bg-base-300 border-none text-[11px]"
          >
            {tag}
          </span>
        </div>
        <div class="mt-1.5 flex items-center gap-2">
          <.money amount={@item.price} locale={@locale} class="font-bold text-brand" />
          <span :if={@sold_out} class="badge badge-error badge-soft badge-sm">
            {gettext("Sold out")}
          </span>
        </div>
      </div>

      <div class="relative shrink-0">
        <img
          :if={@item.photo_url}
          src={@item.photo_url}
          class={["size-24 rounded-field object-cover", @sold_out && "grayscale"]}
        />
        <div :if={!@item.photo_url} class="size-24 rounded-field bg-base-200 grid place-items-center">
          <.icon name="hero-photo" class="size-8 opacity-30" />
        </div>
      </div>
    </div>
    """
  end

  attr :item, Catalog.MenuItem, required: true
  attr :groups, :list, required: true
  attr :selected_option_ids, :any, required: true
  attr :qty, :integer, required: true
  attr :submit_attempted, :boolean, required: true
  attr :locale, :string, required: true

  defp item_detail_sheet(assigns) do
    unsatisfied_ids =
      if assigns.submit_attempted do
        assigns.groups
        |> Ordering.unsatisfied_groups(assigns.selected_option_ids)
        |> MapSet.new(& &1.id)
      else
        MapSet.new()
      end

    line_total =
      detail_total(assigns.item, assigns.groups, assigns.selected_option_ids, assigns.qty)

    assigns = assign(assigns, unsatisfied_ids: unsatisfied_ids, line_total: line_total)

    ~H"""
    <div class="fixed inset-0 z-50">
      <div class="absolute inset-0 bg-black/40" phx-click="close_overlay"></div>
      <div class="absolute inset-x-0 bottom-0 pointer-events-none flex justify-center">
        <div class="pointer-events-auto bg-base-100 rounded-t-box w-full max-w-lg max-h-[85vh] overflow-y-auto shadow-xl">
          <div class="flex justify-center pt-2 pb-1">
            <div class="h-1.5 w-10 rounded-full bg-base-300"></div>
          </div>
          <div class="sticky top-0 bg-base-100 border-b border-base-300 p-4 flex items-start justify-between gap-3">
            <div>
              <h3 class="font-semibold text-lg">{@item.name}</h3>
              <p :if={@item.description} class="text-sm text-base-content/60 mt-0.5">
                {@item.description}
              </p>
            </div>
            <button
              type="button"
              phx-click="close_overlay"
              class="btn btn-circle btn-sm btn-ghost shrink-0"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <form id="add-to-cart-form" phx-submit="add_to_cart" class="p-4 space-y-5">
            <div :for={group <- @groups} class="space-y-2">
              <div class="flex items-center gap-2">
                <span class="font-medium text-sm">{group.name}</span>
                <span class={[
                  "badge badge-sm",
                  MapSet.member?(@unsatisfied_ids, group.id) && "badge-error",
                  !MapSet.member?(@unsatisfied_ids, group.id) && "badge-ghost"
                ]}>
                  {group_requirement_label(group)}
                </span>
              </div>

              <label
                :for={option <- Enum.filter(group.options, & &1.active)}
                class="flex items-center justify-between gap-3 min-h-12 px-1 cursor-pointer"
              >
                <span class="flex items-center gap-2">
                  <input
                    type={if group.max_selections == 1, do: "radio", else: "checkbox"}
                    name={"option-#{group.id}"}
                    checked={MapSet.member?(@selected_option_ids, option.id)}
                    phx-click="toggle_option"
                    phx-value-group-id={group.id}
                    phx-value-option-id={option.id}
                    class={
                      if group.max_selections == 1, do: "radio radio-sm", else: "checkbox checkbox-sm"
                    }
                  />
                  {option.name}
                </span>
                <span
                  :if={delta_label(option.price_delta, @locale)}
                  class="text-sm tabular-nums text-base-content/70"
                >
                  {delta_label(option.price_delta, @locale)}
                </span>
              </label>
            </div>

            <textarea
              name="notes"
              placeholder={gettext("Notes (optional) — e.g. no onions")}
              class="textarea w-full text-sm"
              rows="2"
            ></textarea>

            <div class="sticky bottom-0 bg-base-100 pt-3 -mx-4 px-4 pb-1 border-t border-base-300 flex items-center gap-3">
              <div class="join">
                <button type="button" phx-click="dec_qty" class="btn btn-sm join-item">−</button>
                <span class="btn btn-sm join-item pointer-events-none w-10">{@qty}</span>
                <button type="button" phx-click="inc_qty" class="btn btn-sm join-item">+</button>
              </div>
              <button
                type="submit"
                class="btn flex-1 h-14 bg-brand hover:bg-brand/90 text-brand-content border-brand"
              >
                {gettext("Add")} · <.money amount={@line_total} locale={@locale} />
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  attr :cart, Cart, required: true
  attr :scope, Scope, required: true
  attr :locale, :string, required: true
  attr :checkout_error, :string, default: nil
  attr :charges_enabled, :boolean, required: true
  attr :pay_at_counter_enabled, :boolean, required: true
  attr :payment_method, :atom, required: true

  defp cart_sheet(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50">
      <div class="absolute inset-0 bg-black/40" phx-click="close_overlay"></div>
      <div class="absolute inset-x-0 bottom-0 pointer-events-none flex justify-center">
        <div class="pointer-events-auto bg-base-100 rounded-t-box w-full max-w-lg max-h-[85vh] overflow-y-auto shadow-xl flex flex-col">
          <div class="flex justify-center pt-2 pb-1">
            <div class="h-1.5 w-10 rounded-full bg-base-300"></div>
          </div>
          <div class="sticky top-0 bg-base-100 border-b border-base-300 p-4 flex items-center justify-between">
            <h3 class="font-semibold text-lg">{gettext("Your order")}</h3>
            <button type="button" phx-click="close_overlay" class="btn btn-circle btn-sm btn-ghost">
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <div class="p-4 space-y-4">
            <div class="join w-full">
              <button
                type="button"
                phx-click="set_kind"
                phx-value-kind="dine_in"
                class={[
                  "btn join-item flex-1",
                  @cart.kind == :dine_in && "bg-brand text-brand-content border-brand"
                ]}
              >
                {gettext("Dine in")}
              </button>
              <button
                type="button"
                phx-click="set_kind"
                phx-value-kind="takeaway"
                class={[
                  "btn join-item flex-1",
                  @cart.kind == :takeaway && "bg-brand text-brand-content border-brand"
                ]}
              >
                {gettext("Takeaway")}
              </button>
            </div>

            <div class="divide-y divide-base-300">
              <div :for={line <- @cart.items} id={"cart-line-#{line.id}"} class="py-3">
                <.cart_line line={line} scope={@scope} locale={@locale} />
              </div>
            </div>

            <p :if={@cart.items == []} class="text-sm text-base-content/50 py-6 text-center">
              {gettext("Your cart is empty.")}
            </p>
          </div>

          <div
            :if={@cart.items != []}
            class="sticky bottom-0 bg-base-100 border-t border-base-300 p-4 space-y-3"
          >
            <div class="flex items-center justify-between">
              <span class="font-semibold">{gettext("Total")}</span>
              <.money
                amount={Ordering.cart_total(@scope, @cart)}
                locale={@locale}
                class="font-bold text-lg text-brand"
              />
            </div>

            <p
              :if={!@charges_enabled and !@pay_at_counter_enabled}
              class="text-sm text-base-content/60"
            >
              {gettext("This venue isn't set up to accept payments yet — please ask staff.")}
            </p>

            <form
              :if={@charges_enabled or @pay_at_counter_enabled}
              id="checkout-form"
              phx-submit="place_order"
              class="space-y-3"
            >
              <div :if={@charges_enabled and @pay_at_counter_enabled} class="join w-full">
                <button
                  type="button"
                  phx-click="set_payment_method"
                  phx-value-method="wallet"
                  class={[
                    "btn join-item flex-1",
                    @payment_method == :wallet && "bg-brand text-brand-content border-brand"
                  ]}
                >
                  {gettext("Wallet")}
                </button>
                <button
                  type="button"
                  phx-click="set_payment_method"
                  phx-value-method="cash"
                  class={[
                    "btn join-item flex-1",
                    @payment_method == :cash && "bg-brand text-brand-content border-brand"
                  ]}
                >
                  {gettext("Cash at counter")}
                </button>
              </div>

              <div :if={@payment_method == :wallet}>
                <label for="wallet_msisdn" class="text-sm font-medium">
                  {gettext("Wallet phone number")}
                </label>
                <input
                  type="tel"
                  name="wallet_msisdn"
                  id="wallet_msisdn"
                  placeholder="2526XXXXXXXX"
                  class="input w-full mt-1"
                  required
                />
              </div>

              <p :if={@payment_method == :cash} class="text-sm text-base-content/60">
                {gettext("Pay cash at the counter — you'll get an order number to show staff there.")}
              </p>

              <input type="hidden" name="payment_method" value={@payment_method} />

              <p :if={@checkout_error} class="text-sm text-error">{@checkout_error}</p>
              <button
                type="submit"
                class="btn w-full h-14 bg-brand hover:bg-brand/90 text-brand-content border-brand"
              >
                {if @payment_method == :cash,
                  do: gettext("Place order — pay at counter"),
                  else: gettext("Place order")}
              </button>
            </form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :line, CartItem, required: true
  attr :scope, Scope, required: true
  attr :locale, :string, required: true

  defp cart_line(assigns) do
    ~H"""
    <%= if Ordering.validate_line(@scope, @line) == :ok do %>
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <p class="font-medium">{@line.menu_item.name}</p>
          <p :for={option <- @line.options} class="text-xs text-base-content/60">{option.name}</p>
          <p :if={@line.notes} class="text-xs text-base-content/50 italic">"{@line.notes}"</p>
        </div>
        <.money
          amount={Ordering.line_total(@line)}
          locale={@locale}
          class="font-semibold whitespace-nowrap"
        />
      </div>
      <div class="flex items-center gap-3 mt-2">
        <div class="join">
          <button
            type="button"
            phx-click="dec_line_qty"
            phx-value-id={@line.id}
            class="btn btn-xs join-item"
          >
            −
          </button>
          <span class="btn btn-xs join-item pointer-events-none w-8">{@line.qty}</span>
          <button
            type="button"
            phx-click="inc_line_qty"
            phx-value-id={@line.id}
            class="btn btn-xs join-item"
          >
            +
          </button>
        </div>
        <button
          type="button"
          phx-click="remove_line"
          phx-value-id={@line.id}
          class="btn btn-xs btn-ghost text-error"
        >
          {gettext("Remove")}
        </button>
      </div>
    <% else %>
      <div class="flex items-center justify-between gap-3">
        <p class="text-sm text-warning">
          {gettext("%{name}'s options changed — please remove and re-add it.",
            name: @line.menu_item.name
          )}
        </p>
        <button
          type="button"
          phx-click="remove_line"
          phx-value-id={@line.id}
          class="btn btn-xs btn-outline shrink-0"
        >
          {gettext("Remove")}
        </button>
      </div>
    <% end %>
    """
  end

  attr :cart, Cart, required: true
  attr :scope, Scope, required: true
  attr :locale, :string, required: true

  defp sticky_cart_bar(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="open_cart"
      class="fixed bottom-4 inset-x-4 z-40 bg-brand text-brand-content rounded-full shadow-xl px-5 py-3.5 flex items-center justify-between gap-3 motion-safe:animate-[cart-bar-slide-up_200ms_ease-out]"
    >
      <span class="flex items-center gap-2 font-semibold">
        <span class="badge badge-sm bg-brand-content/20 border-none text-brand-content">
          {Enum.reduce(@cart.items, 0, &(&1.qty + &2))}
        </span>
        {gettext("View cart")}
      </span>
      <.money amount={Ordering.cart_total(@scope, @cart)} locale={@locale} class="font-bold" />
    </button>
    """
  end

  ## Mount

  @impl true
  def mount(%{"slug" => slug}, session, socket) do
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
          Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{venue.id}:ratings")
        end

        guest_token = session["guest_token"]
        menu = Catalog.list_public_menu(scope)

        {:ok,
         socket
         |> assign(:venue, venue)
         |> assign(:current_scope, scope)
         |> assign(:table, resolve_table(scope, session["table_id"]))
         |> assign(:menu, menu)
         |> assign(:daily_limits, Catalog.list_daily_limits(scope))
         |> assign(
           :ratings_summary,
           Feedback.ratings_summary_for_items(scope, menu_item_ids(menu))
         )
         |> assign(:guest_token, guest_token)
         |> assign(:cart, guest_token && Ordering.get_active_cart(scope, guest_token))
         |> assign(
           :active_order,
           guest_token && Ordering.get_active_order_for_guest(scope, guest_token)
         )
         |> assign(:overlay, :none)
         |> assign(:selected_option_ids, MapSet.new())
         |> assign(:detail_qty, 1)
         |> assign(:detail_submit_attempted, false)
         |> assign(:checkout_error, nil)
         |> assign(:payment_method, default_payment_method(venue))
         |> assign(:ordering_status, ordering_status(venue))}
    end
  end

  defp resolve_table(_scope, nil), do: nil
  defp resolve_table(scope, table_id), do: Tenants.get_table(scope, table_id)

  defp remaining_for(item, daily_limits) do
    case Map.get(daily_limits, item.id) do
      nil -> :unlimited
      limit -> Catalog.DailyItemLimit.remaining(limit)
    end
  end

  # Postgres's avg() over an integer column returns a Decimal — "4.3",
  # never a locale/currency concern like Money, so a plain round + string
  # conversion is all this needs (no <.money>-style locale machinery).
  defp format_avg_stars(avg), do: avg |> Decimal.round(1) |> Decimal.to_string()

  # design-qa.md Q2: "Menu shows an honest 'Ordering paused — please
  # order at the counter' state instead of silently failing" — this is
  # the proactive banner that decision calls for, distinct from (and in
  # addition to) checkout/2's own reactive gate/error for a customer who
  # already had a cart built before Busy Mode/hours changed.
  defp ordering_status(venue) do
    cond do
      venue.org.subscription_status == :canceled -> :unavailable
      Venue.paused?(venue) -> :paused
      not Tenants.venue_open?(venue) -> :closed
      true -> :open
    end
  end

  defp ordering_status_message(:paused),
    do: gettext("Ordering paused — please order at the counter")

  defp ordering_status_message(:closed),
    do: gettext("We're closed right now — please check back later.")

  ## PubSub

  @impl true
  def handle_info(:menu_updated, socket) do
    venue = Tenants.get_venue_by_slug(socket.assigns.venue.slug)
    scope = %{socket.assigns.current_scope | venue: venue}

    {:noreply,
     socket
     |> assign(:venue, venue)
     |> assign(:current_scope, scope)
     |> assign(:menu, Catalog.list_public_menu(scope))
     |> assign(:daily_limits, Catalog.list_daily_limits(scope))
     |> assign(:ordering_status, ordering_status(venue))}
  end

  # build-plan.md Feature 17's own verify step: a rating from a customer
  # phone "updates the item's public average" live, on every OTHER
  # customer's already-open menu page too — a dedicated topic, never
  # piggybacked on :menu_updated (that one's about stock/menu edits, an
  # unrelated concern that happens to reload similar assigns).
  def handle_info({:rating_submitted, _menu_item_id}, socket) do
    scope = socket.assigns.current_scope
    summary = Feedback.ratings_summary_for_items(scope, menu_item_ids(socket.assigns.menu))
    {:noreply, assign(socket, :ratings_summary, summary)}
  end

  defp menu_item_ids(menu),
    do: Enum.flat_map(menu, fn {_category, items} -> Enum.map(items, & &1.id) end)

  ## Item detail sheet

  @impl true
  def handle_event("open_item", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Catalog.get_item(scope, id) do
      nil ->
        {:noreply,
         socket
         |> assign(:menu, Catalog.list_public_menu(scope))
         |> put_flash(:error, gettext("That item is no longer available."))}

      item ->
        groups = Catalog.list_item_modifier_groups(scope, item)

        default_ids =
          groups
          |> Enum.flat_map(& &1.options)
          |> Enum.filter(& &1.default)
          |> MapSet.new(& &1.id)

        {:noreply,
         socket
         |> assign(:overlay, {:item, item, groups})
         |> assign(:selected_option_ids, default_ids)
         |> assign(:detail_qty, 1)
         |> assign(:detail_submit_attempted, false)}
    end
  end

  def handle_event("close_overlay", _params, socket) do
    {:noreply, assign(socket, :overlay, :none)}
  end

  def handle_event("toggle_option", %{"group-id" => group_id, "option-id" => option_id}, socket) do
    # A stale click from a just-closed sheet (or a forged event) shouldn't
    # crash the process — graceful no-op, same pattern as with_line/3 below.
    with {:item, _item, groups} <- socket.assigns.overlay,
         %{} = group <- Enum.find(groups, &(&1.id == group_id)) do
      selected = socket.assigns.selected_option_ids

      {:noreply,
       assign(socket, :selected_option_ids, toggle_selection(group, option_id, selected))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("inc_qty", _params, socket) do
    {:noreply, update(socket, :detail_qty, &min(&1 + 1, CartItem.max_qty()))}
  end

  def handle_event("dec_qty", _params, socket) do
    {:noreply, update(socket, :detail_qty, &max(&1 - 1, 1))}
  end

  def handle_event("add_to_cart", %{"notes" => raw_notes}, socket) do
    case socket.assigns.overlay do
      {:item, item, groups} ->
        selected_ids = socket.assigns.selected_option_ids

        if Ordering.unsatisfied_groups(groups, selected_ids) != [] do
          {:noreply, assign(socket, :detail_submit_attempted, true)}
        else
          do_add_to_cart(socket, item, selected_ids, raw_notes)
        end

      # Stale submit from a sheet that's already closed — graceful no-op.
      _ ->
        {:noreply, socket}
    end
  end

  ## Cart sheet

  def handle_event("open_cart", _params, socket) do
    {:noreply, socket |> assign(:overlay, :cart) |> assign(:checkout_error, nil)}
  end

  def handle_event("place_order", params, socket) do
    scope = socket.assigns.current_scope
    method = Map.get(params, "payment_method", "wallet")

    case Ordering.checkout(scope, socket.assigns.cart) do
      {:ok, order} ->
        {:noreply, checkout_succeeded(socket, scope, order, method, params["wallet_msisdn"])}

      {:error, reason} ->
        {:noreply, checkout_failed_for(socket, scope, reason)}
    end
  end

  # design-qa.md Q3 — the venue's own toggle picks which methods appear;
  # a cash-only venue never renders the wallet/cash tab strip at all, so
  # this only fires when both are actually offered.
  def handle_event("set_payment_method", %{"method" => method}, socket) do
    {:noreply, assign(socket, :payment_method, String.to_existing_atom(method))}
  end

  def handle_event("set_kind", %{"kind" => kind}, socket) do
    kind = String.to_existing_atom(kind)
    {:ok, _} = Ordering.set_kind(socket.assigns.current_scope, socket.assigns.cart, kind)
    {:noreply, reload_cart(socket)}
  end

  def handle_event("inc_line_qty", %{"id" => id}, socket) do
    with_line(socket, id, fn line ->
      {:ok, _} =
        Ordering.update_item(socket.assigns.current_scope, line, %{
          "qty" => min(line.qty + 1, CartItem.max_qty())
        })

      reload_cart(socket)
    end)
  end

  def handle_event("dec_line_qty", %{"id" => id}, socket) do
    with_line(socket, id, fn line ->
      if line.qty - 1 < 1 do
        :ok = Ordering.remove_item(socket.assigns.current_scope, line)
      else
        {:ok, _} =
          Ordering.update_item(socket.assigns.current_scope, line, %{"qty" => line.qty - 1})
      end

      reload_cart(socket)
    end)
  end

  def handle_event("remove_line", %{"id" => id}, socket) do
    with_line(socket, id, fn line ->
      :ok = Ordering.remove_item(socket.assigns.current_scope, line)
      reload_cart(socket)
    end)
  end

  ## Item detail sheet — private helpers

  defp toggle_selection(%{max_selections: 1} = group, option_id, selected) do
    group_ids = MapSet.new(group.options, & &1.id)
    without_group = MapSet.difference(selected, group_ids)

    if MapSet.member?(selected, option_id),
      do: without_group,
      else: MapSet.put(without_group, option_id)
  end

  defp toggle_selection(group, option_id, selected) do
    cond do
      MapSet.member?(selected, option_id) ->
        MapSet.delete(selected, option_id)

      group_selected_count(group, selected) >= group.max_selections ->
        selected

      true ->
        MapSet.put(selected, option_id)
    end
  end

  defp group_selected_count(group, selected) do
    group_ids = MapSet.new(group.options, & &1.id)
    MapSet.intersection(selected, group_ids) |> MapSet.size()
  end

  defp do_add_to_cart(socket, item, selected_ids, raw_notes) do
    scope = socket.assigns.current_scope
    existing_token = socket.assigns.guest_token
    guest_token = existing_token || Cart.generate_guest_token()
    table_id = socket.assigns.table && socket.assigns.table.id
    notes = normalize_notes(raw_notes)

    scope
    |> Ordering.add_to_cart(
      guest_token,
      table_id,
      item,
      MapSet.to_list(selected_ids),
      socket.assigns.detail_qty,
      notes
    )
    |> case do
      {:ok, cart} ->
        socket =
          socket
          |> assign(:guest_token, guest_token)
          |> assign(:cart, cart)
          |> assign(:overlay, :none)
          |> put_flash(:info, gettext("Added to cart."))
          |> maybe_persist_guest_token(existing_token, guest_token)

        {:noreply, socket}

      {:error, :item_unavailable} ->
        {:noreply,
         socket
         |> assign(:overlay, :none)
         |> assign(:menu, Catalog.list_public_menu(scope))
         |> assign(:daily_limits, Catalog.list_daily_limits(scope))
         |> put_flash(:error, gettext("Sorry, that item just sold out."))}

      {:error, :options_changed} ->
        {:noreply, assign(socket, :detail_submit_attempted, true)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_error_message(changeset))}
    end
  end

  # The only changeset validation a customer can realistically trip is
  # notes length (qty is server-clamped, never taken from form params) —
  # name that one specifically rather than a generic, unhelpful message.
  defp changeset_error_message(changeset) do
    if Keyword.has_key?(changeset.errors, :notes) do
      gettext("Notes are too long — please shorten them.")
    else
      gettext("Something went wrong — please try again.")
    end
  end

  # A guest_token that already existed (restored from the cookie) is
  # already in the browser — only a freshly minted one needs writing.
  defp maybe_persist_guest_token(socket, existing_token, _guest_token)
       when not is_nil(existing_token),
       do: socket

  defp maybe_persist_guest_token(socket, nil, guest_token) do
    push_event(socket, "persist_guest_token", %{
      token: guest_token,
      max_age: GuestToken.max_age_seconds()
    })
  end

  defp normalize_notes(""), do: nil
  defp normalize_notes(notes), do: notes

  ## Cart sheet — private helpers

  defp checkout_failed(socket, message), do: assign(socket, :checkout_error, message)

  # The order itself is already safe (held, snapshotted) regardless of
  # what happens next — a charge_order/3 or record_cash_intent/2 failure
  # here (e.g. a race on charges_enabled) still lands the customer on the
  # tracker; the order simply expires via the 12-min sweep rather than
  # being silently lost (design-qa.md Q1's zero-order-loss rule).
  defp checkout_succeeded(socket, scope, order, "cash", _wallet_msisdn) do
    case Payments.record_cash_intent(scope, order) do
      {:ok, _payment} -> :ok
      {:error, reason} -> Logger.warning("record_cash_intent failed: #{inspect(reason)}")
    end

    push_navigate(socket, to: ~p"/orders/#{order.guest_token}")
  end

  defp checkout_succeeded(socket, scope, order, _wallet, wallet_msisdn) do
    case Payments.charge_order(scope, order, wallet_msisdn) do
      {:ok, _payment} -> :ok
      {:error, reason} -> Logger.warning("charge_order failed: #{inspect(reason)}")
    end

    push_navigate(socket, to: ~p"/orders/#{order.guest_token}")
  end

  defp default_payment_method(%{charges_enabled: true}), do: :wallet
  defp default_payment_method(_venue), do: :cash

  defp checkout_failed_for(socket, _scope, :venue_closed),
    do: checkout_failed(socket, gettext("Sorry, we're closed right now."))

  defp checkout_failed_for(socket, _scope, :ordering_paused) do
    checkout_failed(
      socket,
      gettext("Ordering is paused right now — please check back shortly.")
    )
  end

  defp checkout_failed_for(socket, _scope, :empty_cart),
    do: checkout_failed(socket, gettext("Your cart is empty."))

  defp checkout_failed_for(socket, _scope, :too_many_active_orders) do
    checkout_failed(
      socket,
      gettext("You already have several active orders — please wait for one to finish.")
    )
  end

  defp checkout_failed_for(socket, _scope, :items_changed) do
    socket
    |> reload_cart()
    |> checkout_failed(gettext("Some items changed — please review your cart and try again."))
  end

  defp checkout_failed_for(socket, scope, :sold_out) do
    socket
    |> reload_cart()
    |> assign(:menu, Catalog.list_public_menu(scope))
    |> assign(:daily_limits, Catalog.list_daily_limits(scope))
    |> checkout_failed(gettext("Sorry, an item just sold out — please review your cart."))
  end

  defp checkout_failed_for(socket, _scope, %Ecto.Changeset{}),
    do: checkout_failed(socket, gettext("Something went wrong — please try again."))

  # Graceful no-op on a stale/forged line id (never in the guest's own
  # already-scoped cart) rather than a crash.
  defp with_line(socket, id, fun) do
    case socket.assigns.cart && Enum.find(socket.assigns.cart.items, &(&1.id == id)) do
      nil -> {:noreply, socket}
      line -> {:noreply, fun.(line)}
    end
  end

  defp reload_cart(socket) do
    assign(
      socket,
      :cart,
      Ordering.get_active_cart(socket.assigns.current_scope, socket.assigns.guest_token)
    )
  end

  ## Pricing helpers (mirror Ordering.line_total/1, but for a cart item
  ## that doesn't exist yet — computed from the open sheet's live selection)

  defp detail_total(item, groups, selected_ids, qty) do
    zero = Money.new!(item.price.currency, 0)

    deltas =
      groups
      |> Enum.flat_map(& &1.options)
      |> Enum.filter(&MapSet.member?(selected_ids, &1.id))
      |> Enum.reduce(zero, &Money.add!(&2, &1.price_delta))

    Money.mult!(Money.add!(item.price, deltas), qty)
  end

  defp group_requirement_label(%{min_selections: same, max_selections: same}),
    do: gettext("Choose %{count}", count: same)

  defp group_requirement_label(%{min_selections: 0, max_selections: max}),
    do: gettext("Up to %{max}", max: max)

  defp group_requirement_label(group),
    do: gettext("Choose %{min}–%{max}", min: group.min_selections, max: group.max_selections)

  defp delta_label(%Money{} = delta, locale) do
    zero = Money.new!(delta.currency, 0)

    case Money.compare!(delta, zero) do
      :eq -> nil
      :gt -> "+" <> format_money(delta, locale)
      :lt -> format_money(delta, locale)
    end
  end
end

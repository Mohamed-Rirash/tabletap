defmodule TabletapWeb.Public.OrderTrackerLive do
  @moduledoc """
  The customer order tracker (build-plan.md Feature 08) — status
  timeline, live ETA, no auth. Reached at `/orders/:guest_token`
  straight after checkout (`Public.MenuLive`'s "Place order" redirects
  here), by re-scanning the table QR or reopening the venue menu while
  an order is active (design-qa.md Q13's banner), or from a bookmarked/
  saved link days later.

  `guest_token` alone carries no venue context, so this resolves like
  `Public.MenuLive`'s slug/qr_token entry points: `Tenants.get_order_by_guest_token/1`
  is the pre-scope, `skip_org_id: true` lookup (see that function's
  moduledoc for why it lives in `Tenants` rather than `Ordering`), then
  `Repo.put_org_id/1` and every subsequent read is normally tenant-scoped.

  Subscribes to `"order:<id>"` — `OrderStateMachine.transition/3`
  broadcasts there after every commit, so status changes appear within
  seconds without a refresh (build-plan.md verify step: "Tracker updates
  within 2s when status changes from IEx").
  """
  use TabletapWeb, :live_view

  alias Tabletap.Accounts
  alias Tabletap.Accounts.Scope
  alias Tabletap.{Feedback, Ordering, Payments, Repo, Tenants}
  alias Tabletap.Ordering.Order

  @step_order [:placed, :accepted, :preparing, :ready, :served]
  @terminal_non_timeline [:cancelled, :expired, :refunded]
  # Call-waiter only makes sense while service is actually in flight —
  # not before payment confirms, not after the food arrived.
  @active_service_statuses [:placed, :accepted, :preparing, :ready]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">{@venue.name}</h1>
        <p class="text-sm text-base-content/60">
          {gettext("Order #%{number}", number: @order.number)}
        </p>
      </div>

      <div
        :if={@order.status == :pending_payment and pending_cash?(@latest_payment)}
        class="rounded-box bg-base-100 border border-base-300 p-6 text-center space-y-2"
      >
        <.icon name="hero-banknotes" class="size-8 mx-auto opacity-40" />
        <p class="font-medium">{gettext("Show this order number at the counter")}</p>
        <p class="text-4xl font-extrabold text-brand tabular-nums">{@order.number}</p>
        <p class="text-sm text-base-content/60">
          {gettext("Pay cash there and staff will fire your order.")}
        </p>
      </div>

      <div
        :if={@order.status == :pending_payment and !pending_cash?(@latest_payment)}
        class="rounded-box bg-base-100 border border-base-300 p-6 text-center space-y-2"
      >
        <.icon name="hero-clock" class="size-8 mx-auto opacity-40 motion-safe:animate-pulse" />
        <p class="font-medium">{gettext("Confirming your payment…")}</p>
        <p class="text-sm text-base-content/60">
          {gettext("This updates automatically — no need to refresh.")}
        </p>
      </div>

      <div
        :if={@order.status in @terminal_non_timeline_status}
        class="rounded-box bg-base-100 border border-base-300 p-6 text-center space-y-2"
      >
        <.icon name="hero-x-circle" class="size-8 mx-auto text-error" />
        <p class="font-medium">{terminal_message(@order, @latest_payment)}</p>
      </div>

      <div
        :if={@order.status == :served}
        class="mb-6 rounded-box bg-success/10 border border-success/30 p-6 text-center space-y-2"
      >
        <.icon name="hero-check-badge" class="size-10 mx-auto text-success" />
        <p class="font-semibold text-lg">{gettext("Order served — enjoy!")}</p>
      </div>

      <div
        :if={@serve_qr_svg}
        class="mb-6 rounded-box bg-base-100 border border-base-300 p-6 text-center space-y-2"
      >
        <p class="font-medium">{gettext("Show this to staff to collect your order")}</p>
        <div class="w-40 mx-auto [&_svg]:w-full [&_svg]:h-auto">
          {Phoenix.HTML.raw(@serve_qr_svg)}
        </div>
      </div>

      <.status_timeline
        :if={@order.status not in [:pending_payment | @terminal_non_timeline_status]}
        order={@order}
        eta_minutes={@eta_minutes}
      />

      <div :if={@order.status in @active_service_statuses} class="mt-6">
        <button
          :if={show_call_waiter?(@venue, @order)}
          type="button"
          phx-click="call_waiter"
          disabled={@waiter_called}
          class="btn btn-outline w-full"
        >
          <.icon name="hero-hand-raised" class="size-4" />
          {if @waiter_called,
            do: gettext("Waiter called — on the way"),
            else: gettext("Call waiter")}
        </button>
        <p
          :if={@venue.fulfillment_mode == :pickup}
          class="text-sm text-base-content/60 text-center"
        >
          {gettext("Need help? Ask at the counter.")}
        </p>
      </div>

      <.signup_prompt
        :if={is_nil(@order.customer_user_id) and @order.status != :pending_payment}
        form={@signup_form}
        requested={@signup_requested}
      />

      <div class="mt-6 rounded-box bg-base-100 border border-base-300 p-4">
        <h2 class="font-semibold mb-3">{gettext("Order details")}</h2>
        <div class="divide-y divide-base-300">
          <div :for={item <- @order.items} class="py-2">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <p class="font-medium">{item.qty}× {item.name_snapshot}</p>
                <p :for={mod <- item.modifiers} class="text-xs text-base-content/60">
                  {mod.name_snapshot}
                </p>
                <p :if={item.notes} class="text-xs text-base-content/50 italic">"{item.notes}"</p>
              </div>
              <.money amount={item.line_total} locale={@venue.locale} class="whitespace-nowrap" />
            </div>

            <.rating_widget
              :if={@order.status in [:served, :closed]}
              item={item}
              rated={MapSet.member?(@rated_item_ids, item.id)}
              draft={Map.get(@draft_ratings, item.id, %{stars: 0, comment: ""})}
            />
          </div>
        </div>
        <div class="flex items-center justify-between mt-3 pt-3 border-t border-base-300">
          <span class="font-semibold">{gettext("Total")}</span>
          <.money amount={@order.total} locale={@venue.locale} class="font-bold text-brand" />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # build-plan.md Feature 17 — "stars per item + optional comment, one
  # per order item." Tapping a star only stages it (`select_stars`, a
  # plain assign update — no write yet); the comment box only appears
  # once something's staged, and the actual `Feedback.rate_item/5` call
  # happens on the explicit submit, so a customer reconsidering their
  # star pick before hitting Submit never creates a stray row (the DB
  # unique index on `order_item_id` means that stray row would then
  # block their real rating).
  attr :item, :any, required: true
  attr :rated, :boolean, required: true
  attr :draft, :map, required: true

  defp rating_widget(assigns) do
    ~H"""
    <div :if={@rated} class="mt-2 text-sm text-success flex items-center gap-1">
      <.icon name="hero-check-circle" class="size-4" /> {gettext("Thanks for rating this!")}
    </div>

    <div :if={!@rated} class="mt-2">
      <div class="flex items-center gap-1">
        <button
          :for={n <- 1..5}
          type="button"
          phx-click="select_stars"
          phx-value-item_id={@item.id}
          phx-value-stars={n}
          class="p-0.5"
          aria-label={gettext("Rate %{n} stars", n: n)}
        >
          <.icon
            name={if n <= @draft.stars, do: "hero-star-solid", else: "hero-star"}
            class={["size-5", n <= @draft.stars && "text-warning"]}
          />
        </button>
      </div>

      <.form
        :if={@draft.stars > 0}
        for={%{}}
        as={:rating}
        phx-submit="submit_rating"
        class="flex gap-2 mt-2"
      >
        <input type="hidden" name="item_id" value={@item.id} />
        <input
          type="text"
          name="comment"
          value={@draft.comment}
          placeholder={gettext("Optional comment…")}
          class="input input-sm flex-1"
        />
        <button type="submit" class="btn btn-sm btn-primary shrink-0">{gettext("Submit")}</button>
      </.form>
    </div>
    """
  end

  attr :order, Order, required: true
  attr :eta_minutes, :integer, required: true

  defp status_timeline(assigns) do
    assigns = assign(assigns, :steps, @step_order)

    ~H"""
    <div class="rounded-box bg-base-100 border border-base-300 p-6">
      <.timeline_step
        :for={step <- @steps}
        step={step}
        state={step_state(step, @order.status)}
        timestamp={step_timestamp(@order, step)}
        eta_minutes={@eta_minutes}
        is_last={step == :served}
      />
    </div>
    """
  end

  attr :step, :atom, required: true
  attr :state, :atom, required: true, doc: ":done | :current | :upcoming"
  attr :timestamp, :any, default: nil
  attr :eta_minutes, :integer, required: true
  attr :is_last, :boolean, default: false

  defp timeline_step(assigns) do
    ~H"""
    <div class="flex gap-3">
      <div class="flex flex-col items-center">
        <span class={[
          "size-4 rounded-full shrink-0",
          @state == :upcoming && "bg-base-300",
          @state != :upcoming && step_bg_class(@step),
          @state == :current && "motion-safe:animate-pulse"
        ]}></span>
        <div
          :if={!@is_last}
          class={[
            "w-0.5 flex-1 min-h-8",
            @state == :done && step_bg_class(@step),
            @state != :done && "bg-base-300"
          ]}
        >
        </div>
      </div>
      <div class="pb-8">
        <p class={["font-medium", @state == :upcoming && "text-base-content/40"]}>
          {step_label(@step)}
        </p>
        <p :if={@timestamp} class="text-xs text-base-content/50">
          {Calendar.strftime(@timestamp, "%H:%M")}
        </p>
        <p :if={@state == :current} class="text-xs text-base-content/60 mt-0.5">
          {gettext("~%{minutes} min", minutes: @eta_minutes)}
        </p>
      </div>
    </div>
    """
  end

  # design-qa.md's "Save your history" flow (build-plan.md Feature 16):
  # a guest never has to sign up to order, but every order they place
  # under this `guest_token` becomes claimable the moment they do —
  # `Ordering.link_guest_orders_to_customer/2` finds them all at once by
  # `guest_token`, not just this one.
  attr :form, :any, required: true
  attr :requested, :boolean, required: true

  defp signup_prompt(assigns) do
    ~H"""
    <div class="mt-6 rounded-box bg-base-100 border border-base-300 p-4">
      <div :if={!@requested}>
        <h2 class="font-semibold">{gettext("Save your order history")}</h2>
        <p class="text-sm text-base-content/60 mb-3">
          {gettext("Get a magic link to see every order, at every venue, in one place.")}
        </p>
        <.form for={@form} id="signup-form" phx-submit="request_signup" class="flex gap-2">
          <input
            type="email"
            name={@form[:email].name}
            value={@form[:email].value}
            placeholder={gettext("you@example.com")}
            required
            class="input flex-1"
          />
          <button type="submit" class="btn btn-primary shrink-0">{gettext("Save")}</button>
        </.form>
      </div>
      <div :if={@requested} class="flex items-center gap-2 text-sm text-base-content/70">
        <.icon name="hero-envelope" class="size-4 shrink-0" />
        {gettext("If that email works, a magic link is on its way — click it to save this history.")}
      </div>
    </div>
    """
  end

  @impl true
  def mount(%{"guest_token" => guest_token}, _session, socket) do
    case Tenants.get_order_by_guest_token(guest_token) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Order not found."))
         |> redirect(to: ~p"/")}

      resolved ->
        Repo.put_org_id(resolved.org_id)
        scope = %Scope{org: resolved.venue.org, venue: resolved.venue, role: :guest}
        order = Ordering.get_order(scope, resolved.id)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Tabletap.PubSub, "order:#{order.id}")
        end

        client_ip = if connected?(socket), do: TabletapWeb.RateLimiter.client_ip(socket)

        {:ok,
         socket
         |> assign(:hide_utility_bar, true)
         |> assign(:venue, resolved.venue)
         |> assign(:current_scope, scope)
         |> assign(:order, order)
         |> assign(:eta_minutes, Ordering.estimated_minutes(scope, order))
         |> assign(:latest_payment, Payments.get_latest_payment_for_order(scope, order.id))
         |> assign(:terminal_non_timeline_status, @terminal_non_timeline)
         |> assign(:active_service_statuses, @active_service_statuses)
         |> assign(:waiter_called, false)
         |> assign(:serve_qr_svg, serve_qr_svg(scope, order))
         |> assign(:signup_form, to_form(%{"email" => nil}, as: "signup"))
         |> assign(:signup_requested, false)
         |> assign(:client_ip, client_ip)
         |> assign(:draft_ratings, %{})
         |> assign_rated_item_ids()}
    end
  end

  @impl true
  def handle_event("call_waiter", _params, socket) do
    scope = socket.assigns.current_scope

    case Ordering.call_waiter(scope, socket.assigns.order) do
      {:ok, _call} ->
        {:noreply, assign(socket, :waiter_called, true)}

      # Pickup venue / no table — the button never renders for these, so
      # this is a stale/forged event; a graceful no-op, not a crash.
      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("request_signup", %{"signup" => %{"email" => email}}, socket) do
    # Same non-enumeration shape as UserLive.Login's own magic-link
    # request (design-qa.md Q47) — identical response whether the email
    # is new, already has an account, or the request got rate-limited.
    if TabletapWeb.RateLimiter.check({:auth_email, socket.assigns.client_ip}) == :ok do
      if user = find_or_register_customer(email) do
        guest_token = socket.assigns.order.guest_token

        Accounts.deliver_login_instructions(
          user,
          &url(~p"/users/log-in/#{&1}?#{%{guest_token: guest_token}}")
        )
      end
    end

    {:noreply, assign(socket, :signup_requested, true)}
  end

  # build-plan.md Feature 17 — a star tap only stages the pick locally;
  # nothing is written until "submit_rating" (see rating_widget/1's own
  # moduledoc-style comment for why).
  def handle_event("select_stars", %{"item_id" => item_id, "stars" => stars}, socket) do
    draft = Map.get(socket.assigns.draft_ratings, item_id, %{stars: 0, comment: ""})
    updated = %{draft | stars: String.to_integer(stars)}

    {:noreply, update(socket, :draft_ratings, &Map.put(&1, item_id, updated))}
  end

  def handle_event("submit_rating", %{"item_id" => item_id, "comment" => comment}, socket) do
    scope = socket.assigns.current_scope
    order = socket.assigns.order
    order_item = Enum.find(order.items, &(&1.id == item_id))
    stars = socket.assigns.draft_ratings |> Map.get(item_id, %{}) |> Map.get(:stars, 0)

    opts = [comment: normalize_notes(comment)]

    case Feedback.rate_item(scope, order, order_item, stars, opts) do
      {:ok, _rating} ->
        {:noreply,
         socket
         |> update(:draft_ratings, &Map.delete(&1, item_id))
         |> update(:rated_item_ids, &MapSet.put(&1, item_id))}

      # A double-tapped submit, or a stray retry after the order moved
      # past :served/:closed mid-visit — reload the real state rather
      # than trusting the stale local draft either way.
      {:error, _reason} ->
        {:noreply,
         socket |> update(:draft_ratings, &Map.delete(&1, item_id)) |> assign_rated_item_ids()}
    end
  end

  defp find_or_register_customer(email) do
    case Accounts.get_user_by_email(email) do
      %Accounts.User{} = user ->
        user

      nil ->
        case Accounts.register_user(%{"email" => email}) do
          {:ok, user} -> user
          {:error, _changeset} -> nil
        end
    end
  end

  defp assign_rated_item_ids(socket) do
    scope = socket.assigns.current_scope
    item_ids = Enum.map(socket.assigns.order.items, & &1.id)
    assign(socket, :rated_item_ids, Feedback.rated_order_item_ids(scope, item_ids))
  end

  defp normalize_notes(""), do: nil
  defp normalize_notes(notes), do: notes

  @impl true
  def handle_info(:order_updated, socket) do
    scope = socket.assigns.current_scope
    order = Ordering.get_order(scope, socket.assigns.order.id)

    {:noreply,
     socket
     |> assign(:order, order)
     |> assign(:eta_minutes, Ordering.estimated_minutes(scope, order))
     |> assign(:latest_payment, Payments.get_latest_payment_for_order(scope, order.id))
     |> assign(:serve_qr_svg, serve_qr_svg(scope, order))
     |> assign_rated_item_ids()}
  end

  # Q46: pickup venues get "Ask at the counter", never a call button;
  # a takeaway order at a waiter venue has no table to call from either.
  defp show_call_waiter?(venue, order) do
    venue.fulfillment_mode == :waiter and order.table_id != nil
  end

  # build-plan.md Feature 11 (Q18): a takeaway order, or any order at a
  # pickup-mode venue, has no table for staff to scan at serve time — the
  # customer shows this instead. Whether that's the case is exactly what
  # `Ordering.serve_token/2` already decided (its guest_token branch vs.
  # its table-qr_token branch) — reusing it here keeps this in sync with
  # what a scan is actually checked against, rather than re-deriving the
  # same table_id/fulfillment_mode branching a second time. Encodes the
  # raw token, not a URL — it's shown to be scanned, never navigated to.
  defp serve_qr_svg(scope, %Order{status: :ready} = order) do
    if Ordering.serve_token(scope, order) == order.guest_token do
      {:ok, svg} =
        order.guest_token
        |> QRCode.create(:high)
        |> QRCode.render(:svg, %QRCode.Render.SvgSettings{
          qrcode_color: "#000000",
          background_color: "#ffffff",
          scale: 5
        })

      svg
    end
  end

  defp serve_qr_svg(_scope, %Order{}), do: nil

  defp step_state(step, current_status) do
    step_index = Enum.find_index(@step_order, &(&1 == step))
    current_index = Enum.find_index(@step_order, &(&1 == current_status)) || 0

    cond do
      step_index < current_index -> :done
      step_index == current_index -> :current
      true -> :upcoming
    end
  end

  defp step_timestamp(order, :placed), do: order.placed_at
  defp step_timestamp(order, :accepted), do: order.accepted_at
  defp step_timestamp(_order, :preparing), do: nil
  defp step_timestamp(order, :ready), do: order.ready_at
  defp step_timestamp(order, :served), do: order.served_at

  defp step_label(:placed), do: gettext("Placed")
  defp step_label(:accepted), do: gettext("Accepted")
  defp step_label(:preparing), do: gettext("Preparing")
  defp step_label(:ready), do: gettext("Ready")
  defp step_label(:served), do: gettext("Served")

  defp step_bg_class(:placed), do: "bg-status-placed"
  defp step_bg_class(:accepted), do: "bg-info"
  defp step_bg_class(:preparing), do: "bg-status-preparing"
  defp step_bg_class(:ready), do: "bg-success"
  defp step_bg_class(:served), do: "bg-status-served"

  # Q21 late-success resurrection: the order expired, but a payment for
  # it still ended up refunded — meaning it *was* briefly charged before
  # the sold-out re-reservation failed. That's a materially different
  # story for the customer than a plain never-charged expiry.
  defp terminal_message(%Order{status: :expired}, %{status: :refunded}) do
    gettext("Sorry — this item sold out while your payment was confirming. You've been refunded.")
  end

  defp terminal_message(%Order{status: :cancelled}, _payment),
    do: gettext("This order was cancelled.")

  # design-qa.md Q26 — a cash order's hold can expire before the customer
  # reaches the counter; the cashier's own Revive flow brings it back, so
  # this points them there rather than implying the order is dead.
  defp terminal_message(%Order{status: :expired} = order, %{provider: :cash}) do
    gettext(
      "Your hold expired — show order number %{number} at the counter and staff can revive it.",
      number: order.number
    )
  end

  defp terminal_message(%Order{status: :expired}, _payment),
    do: gettext("This order expired before payment was confirmed.")

  defp terminal_message(%Order{status: :refunded}, _payment),
    do: gettext("This order was refunded.")

  defp pending_cash?(%{provider: :cash, status: :pending}), do: true
  defp pending_cash?(_payment), do: false
end

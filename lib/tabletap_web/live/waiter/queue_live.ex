defmodule TabletapWeb.Waiter.QueueLive do
  @moduledoc """
  The waiter's phone (build-plan.md Feature 10; role-features.md "Waiter —
  Waiter PWA (mobile, one-thumb)"): shift toggle, FIFO assigned queue
  with NEXT UP pinned, accept buttons, order detail inline on each card
  (items + customizations + table — never truncated, code-standards.md's
  notes invariant), and the venue-wide claim board as a second tab.

  On-shift + connected = tracked in `TabletapWeb.Presence` on
  `venue:{id}:staff` — that's what makes this waiter an assignment
  candidate; clocking out (or the ~30s flap grace expiring after a
  dropped socket) removes them. Clocking out with open orders forces the
  Q44-style handoff: everything on their plate goes to the claim board.

  Boards re-read DB state on every mount/reconnect — PubSub is an
  optimization, never the source of truth (architecture.md
  "Reliability").
  """
  use TabletapWeb, :live_view

  alias Tabletap.{Notifications, Ordering, Staffing}
  alias TabletapWeb.Presence

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mb-4 flex items-center justify-between gap-3">
        <div>
          <h1 class="text-xl font-bold">{@current_scope.venue.name}</h1>
          <p class="text-sm text-base-content/60">{gettext("Waiter")}</p>
        </div>
        <button
          :if={!@on_shift}
          type="button"
          phx-click="clock_in"
          class="btn btn-primary"
        >
          {gettext("Start shift")}
        </button>
        <button
          :if={@on_shift}
          type="button"
          phx-click="clock_out"
          class="btn btn-outline"
        >
          {gettext("End shift")}
        </button>
      </div>

      <.push_subscribe_button vapid_public_key={@vapid_public_key} />

      <div :if={!@on_shift} class="rounded-box bg-base-100 border border-base-300 p-6 text-center">
        <.icon name="hero-clock" class="size-8 mx-auto opacity-40" />
        <p class="mt-2 font-medium">{gettext("You're off shift")}</p>
        <p class="text-sm text-base-content/60">
          {gettext("Start your shift to receive orders.")}
        </p>
      </div>

      <div :if={@on_shift}>
        <div role="tablist" class="tabs tabs-box mb-4">
          <button
            type="button"
            role="tab"
            phx-click="set_tab"
            phx-value-tab="queue"
            class={["tab flex-1", @tab == :queue && "tab-active"]}
          >
            {gettext("My queue")}
            <span :if={@queue != []} class="badge badge-sm ms-1.5">{length(@queue)}</span>
          </button>
          <button
            type="button"
            role="tab"
            phx-click="set_tab"
            phx-value-tab="claim"
            class={["tab flex-1", @tab == :claim && "tab-active"]}
          >
            {gettext("Claim board")}
            <span :if={@claim_board != []} class="badge badge-sm badge-warning ms-1.5">
              {length(@claim_board)}
            </span>
          </button>
        </div>

        <div :if={@tab == :queue} class="space-y-3">
          <.order_card
            :for={{order, index} <- Enum.with_index(@queue)}
            order={order}
            next_up={index == 0}
            called={MapSet.member?(@called_order_ids, order.id)}
            locale={@current_scope.venue.locale}
            board={:queue}
          />
          <p :if={@queue == []} class="text-sm text-base-content/50 py-8 text-center">
            {gettext("No orders yet — new assignments appear here.")}
          </p>
        </div>

        <div :if={@tab == :claim} class="space-y-3">
          <.order_card
            :for={order <- @claim_board}
            order={order}
            next_up={false}
            called={false}
            locale={@current_scope.venue.locale}
            board={:claim}
          />
          <p :if={@claim_board == []} class="text-sm text-base-content/50 py-8 text-center">
            {gettext("Nothing unclaimed right now.")}
          </p>
        </div>
      </div>

      <.scan_modal :if={@scanning_order_id} />
    </Layouts.app>
    """
  end

  defp scan_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50">
      <div class="absolute inset-0 bg-black/80"></div>
      <div class="absolute inset-0 flex flex-col items-center justify-center gap-4 p-4">
        <video
          id="qr-scan-video"
          phx-hook="QrScanner"
          phx-update="ignore"
          class="w-full max-w-sm aspect-square rounded-box bg-black object-cover"
          muted
          playsinline
        ></video>
        <p class="text-white text-sm text-center max-w-sm">
          {gettext(
            "Scan the table's QR code — for takeaway or pickup orders, scan the customer's tracker screen instead."
          )}
        </p>
        <button
          type="button"
          phx-click="close_scan"
          class="btn btn-outline btn-sm text-white border-white/40"
        >
          {gettext("Cancel")}
        </button>
      </div>
    </div>
    """
  end

  attr :order, :any, required: true
  attr :next_up, :boolean, required: true
  attr :called, :boolean, required: true
  attr :locale, :string, required: true
  attr :board, :atom, required: true, doc: ":queue or :claim"

  defp order_card(assigns) do
    ~H"""
    <div
      id={"order-#{@order.id}"}
      class={[
        "rounded-box bg-base-100 border p-4",
        @next_up && "border-brand border-2",
        !@next_up && "border-base-300"
      ]}
    >
      <div class="flex items-start justify-between gap-3 mb-2">
        <div>
          <span :if={@next_up} class="badge badge-sm bg-brand text-brand-content border-none mb-1">
            {gettext("NEXT UP")}
          </span>
          <span :if={@called} class="badge badge-sm badge-warning mb-1 motion-safe:animate-pulse">
            {gettext("Table calling!")}
          </span>
          <p class="font-bold text-lg">
            {gettext("Order #%{number}", number: @order.number)}
          </p>
          <p :if={@order.table} class="text-2xl font-bold text-brand">
            {gettext("Table %{number}", number: @order.table.number)}
          </p>
          <p :if={!@order.table} class="text-sm font-medium text-base-content/70">
            {order_kind_label(@order.kind)}
          </p>
        </div>
        <span class="badge badge-outline">{status_label(@order.status)}</span>
      </div>

      <div class="divide-y divide-base-200 mb-3">
        <div :for={item <- @order.items} class="py-1.5">
          <p class="font-medium">{item.qty}× {item.name_snapshot}</p>
          <p :for={mod <- item.modifiers} class="text-xs text-base-content/60 ps-4">
            {mod.name_snapshot}
          </p>
          <p :if={item.notes} class="text-xs text-warning ps-4">"{item.notes}"</p>
        </div>
      </div>

      <div class="flex gap-2">
        <button
          :if={@board == :queue && @order.status == :placed}
          type="button"
          phx-click="accept_order"
          phx-value-id={@order.id}
          class="btn btn-primary flex-1"
        >
          {gettext("Accept")}
        </button>
        <button
          :if={@board == :claim}
          type="button"
          phx-click="claim_order"
          phx-value-id={@order.id}
          class="btn btn-primary flex-1"
        >
          {gettext("Claim")}
        </button>
        <button
          :if={@board == :queue && @order.status == :ready && is_nil(@order.flag)}
          type="button"
          phx-click="open_scan"
          phx-value-id={@order.id}
          class="btn btn-primary flex-1"
        >
          <.icon name="hero-qr-code" class="size-4" /> {gettext("Scan to serve")}
        </button>
        <button
          :if={@board == :queue && @order.status == :ready && is_nil(@order.flag)}
          type="button"
          phx-click="mark_unserveable"
          phx-value-id={@order.id}
          class="btn btn-ghost btn-sm text-error"
        >
          {gettext("Can't find customer")}
        </button>
        <span :if={@order.flag == :unserveable} class="badge badge-error badge-soft self-center">
          {gettext("Flagged for manager")}
        </span>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    on_shift = Staffing.get_open_shift(scope) != nil

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "waiter:#{scope.membership.id}")
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{scope.venue.id}:claim_board")
      if on_shift, do: track_presence(scope)
    end

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:on_shift, on_shift)
     |> assign(:tab, :queue)
     |> assign(:called_order_ids, MapSet.new())
     |> assign(:scanning_order_id, nil)
     |> assign(:vapid_public_key, Notifications.vapid_public_key())
     |> reload_boards()}
  end

  @impl true
  def handle_event("push_subscribe", params, socket) do
    Notifications.subscribe(socket.assigns.current_scope.user, params)
    {:noreply, socket}
  end

  def handle_event("clock_in", _params, socket) do
    scope = socket.assigns.current_scope

    case Staffing.clock_in(scope) do
      {:ok, _shift} ->
        track_presence(scope)
        {:noreply, socket |> assign(:on_shift, true) |> reload_boards()}

      {:error, :already_clocked_in} ->
        {:noreply, socket |> assign(:on_shift, true) |> reload_boards()}
    end
  end

  def handle_event("clock_out", _params, socket) do
    scope = socket.assigns.current_scope

    case Staffing.clock_out(scope) do
      {:ok, _shift} ->
        # Off-shift handoff (role-features.md): open orders never stay
        # on an off-shift waiter's plate.
        released = Ordering.release_orders_to_claim_board(scope, scope.membership.id)
        Presence.untrack(self(), Presence.staff_topic(scope.venue.id), scope.membership.id)

        socket =
          if released > 0 do
            put_flash(
              socket,
              :info,
              gettext("%{count} open order(s) moved to the claim board.", count: released)
            )
          else
            socket
          end

        {:noreply, socket |> assign(:on_shift, false) |> reload_boards()}

      {:error, :not_clocked_in} ->
        {:noreply, assign(socket, :on_shift, false)}
    end
  end

  def handle_event("set_tab", %{"tab" => tab}, socket) when tab in ["queue", "claim"] do
    {:noreply, assign(socket, :tab, String.to_existing_atom(tab))}
  end

  def handle_event("accept_order", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Ordering.get_order(scope, id) do
      nil ->
        {:noreply, reload_boards(socket)}

      order ->
        case Ordering.accept_order(scope, order) do
          {:ok, _order} ->
            {:noreply, reload_boards(socket)}

          {:error, _reason} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("That order moved on — refreshing."))
             |> reload_boards()}
        end
    end
  end

  def handle_event("claim_order", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Ordering.claim_order(scope, id) do
      {:ok, _order} ->
        {:noreply, socket |> assign(:tab, :queue) |> reload_boards()}

      {:error, :already_claimed} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Someone else got it first."))
         |> reload_boards()}
    end
  end

  def handle_event("mark_unserveable", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Ordering.get_order(scope, id) do
      nil ->
        {:noreply, reload_boards(socket)}

      order ->
        {:ok, _} = Ordering.mark_unserveable(scope, order)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Flagged — a manager will resolve it."))
         |> reload_boards()}
    end
  end

  def handle_event("open_scan", %{"id" => id}, socket) do
    {:noreply, assign(socket, :scanning_order_id, id)}
  end

  def handle_event("close_scan", _params, socket) do
    {:noreply, assign(socket, :scanning_order_id, nil)}
  end

  def handle_event("qr_scanned", %{"value" => value}, socket) do
    scope = socket.assigns.current_scope

    order =
      socket.assigns.scanning_order_id &&
        Ordering.get_order(scope, socket.assigns.scanning_order_id)

    case order && Ordering.confirm_served_by_scan(scope, order, value) do
      {:ok, _served} ->
        {:noreply,
         socket
         |> assign(:scanning_order_id, nil)
         |> put_flash(:info, gettext("Served — nice work."))
         |> reload_boards()}

      {:error, :token_mismatch} ->
        {:noreply,
         put_flash(socket, :error, gettext("That's not the right table or customer — try again."))}

      # Order vanished mid-scan, or moved on (already served/reassigned
      # elsewhere) while the camera was open — never a crash.
      _stale_or_not_ready ->
        {:noreply,
         socket
         |> assign(:scanning_order_id, nil)
         |> put_flash(:error, gettext("That order moved on — refreshing."))
         |> reload_boards()}
    end
  end

  def handle_event("scan_error", %{"message" => message}, socket) do
    {:noreply,
     socket
     |> assign(:scanning_order_id, nil)
     |> put_flash(:error, gettext("Couldn't access the camera: %{message}", message: message))}
  end

  @impl true
  def handle_info({:order_assigned, _order_id}, socket), do: {:noreply, reload_boards(socket)}
  def handle_info({:order_unassigned, _order_id}, socket), do: {:noreply, reload_boards(socket)}
  def handle_info({:order_needs_claim, _order_id}, socket), do: {:noreply, reload_boards(socket)}
  def handle_info({:order_claimed, _order_id}, socket), do: {:noreply, reload_boards(socket)}

  # Feature 14 — the kitchen's Ready tap (and its Q25 undo retraction)
  # lands here live; the queue reload flips the card to "Scan to serve"
  # (or back off it) without the waiter touching anything.
  def handle_info({:order_ready, order_id}, socket) do
    order = Enum.find(socket.assigns.queue, &(&1.id == order_id))

    socket =
      if order do
        put_flash(
          socket,
          :info,
          gettext("Order #%{number} is ready for pickup!", number: order.number)
        )
      else
        socket
      end

    {:noreply, reload_boards(socket)}
  end

  def handle_info({:order_ready_retracted, _order_id}, socket),
    do: {:noreply, reload_boards(socket)}

  def handle_info({:waiter_called, order_id}, socket) do
    {:noreply,
     socket
     |> update(:called_order_ids, &MapSet.put(&1, order_id))
     |> put_flash(:info, gettext("A table is calling you!"))
     |> reload_boards()}
  end

  def handle_info({:waiter_gone, _membership_id}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp track_presence(scope) do
    {:ok, _ref} =
      Presence.track(
        self(),
        Presence.staff_topic(scope.venue.id),
        scope.membership.id,
        %{role: :waiter}
      )
  end

  defp reload_boards(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:queue, Ordering.list_waiter_queue(scope))
    |> assign(:claim_board, Ordering.list_claim_board(scope))
  end

  defp order_kind_label(:takeaway), do: gettext("Takeaway")
  defp order_kind_label(:counter), do: gettext("Counter")
  defp order_kind_label(_), do: gettext("Dine in")

  defp status_label(:placed), do: gettext("New")
  defp status_label(:accepted), do: gettext("Accepted")
  defp status_label(:preparing), do: gettext("Preparing")
  defp status_label(:ready), do: gettext("Ready")
  defp status_label(other), do: other |> to_string() |> String.capitalize()
end

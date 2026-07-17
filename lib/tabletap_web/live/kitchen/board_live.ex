defmodule TabletapWeb.Kitchen.BoardLive do
  @moduledoc """
  The KDS (build-plan.md Feature 14; ui-rules.md "Surface: Kitchen
  Display"): three status columns — New | Preparing | Ready — read from
  a meter away on an always-on dark tablet. Tickets advance via the
  full-width footer strip (Start → Ready), one step back via the header
  undo (design-qa.md Q25), and modifiers/notes render in full, always —
  "no onions" hidden is a wrong dish cooked (Q12's invariant).

  Columns are LiveView streams (ui-registry.md "Real-time update
  pattern"): the `{:order_updated, id}` broadcast re-fetches just that
  order and `stream_insert`/`stream_delete`s the one ticket — never a
  whole-board re-query per event, since this page runs for a 12h shift.
  A full re-read only happens on mount/reconnect and on a stale tap
  (PubSub is an optimization, never the source of truth).

  The elapsed/overdue timer ticks client-side (`.TicketTimer` — the
  server sends `placed_at` once; no per-second server messages), the
  new-ticket sound cue is toggleable per device (`.KdsSound`,
  localStorage), and `.KdsReload` offers a refresh after 12h so a
  shift-long browser session never quietly degrades.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Ordering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.kds flash={@flash}>
      <div class="h-dvh flex flex-col overflow-hidden">
        <header class="flex-none flex items-center justify-between gap-3 border-b border-base-300 px-4 py-2">
          <div class="flex items-baseline gap-2 min-w-0">
            <h1 class="text-lg font-bold truncate">{@current_scope.venue.name}</h1>
            <span class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
              {gettext("Kitchen")}
            </span>
          </div>
          <button
            id="kds-sound-toggle"
            type="button"
            phx-hook=".KdsSound"
            phx-update="ignore"
            class="btn btn-ghost btn-sm"
            aria-label={gettext("Toggle new-ticket sound")}
          >
            <span data-sound-on class="hidden items-center gap-1.5">
              <.icon name="hero-speaker-wave" class="size-4" /> {gettext("Sound on")}
            </span>
            <span data-sound-off class="hidden items-center gap-1.5">
              <.icon name="hero-speaker-x-mark" class="size-4" /> {gettext("Sound off")}
            </span>
          </button>
        </header>

        <div class="flex-1 min-h-0 grid grid-cols-3 gap-3 p-3">
          <.kds_column
            title={gettext("New")}
            count={@counts.new}
            accent="text-status-placed"
            stream_id="new_orders"
            stream={@streams.new_orders}
            empty={gettext("No new tickets")}
          />
          <.kds_column
            title={gettext("Preparing")}
            count={@counts.preparing}
            accent="text-status-preparing"
            stream_id="preparing_orders"
            stream={@streams.preparing_orders}
            empty={gettext("Nothing on the fire")}
          />
          <.kds_column
            title={gettext("Ready")}
            count={@counts.ready}
            accent="text-success"
            stream_id="ready_orders"
            stream={@streams.ready_orders}
            empty={gettext("Nothing waiting for pickup")}
          />
        </div>
      </div>

      <div
        id="kds-reload-prompt"
        phx-hook=".KdsReload"
        phx-update="ignore"
        class="hidden fixed bottom-4 inset-x-0 z-40 justify-center"
      >
        <div class="flex items-center gap-3 rounded-box bg-base-100 border border-warning/40 shadow-lg px-4 py-3">
          <p class="text-sm">
            {gettext("This screen has been running a long time — refresh to keep it snappy.")}
          </p>
          <button type="button" data-reload class="btn btn-warning btn-sm">
            {gettext("Refresh")}
          </button>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".TicketTimer">
        export default {
          mounted() {
            this.tick()
            this.timer = setInterval(() => this.tick(), 1000)
          },
          updated() {
            this.tick()
          },
          destroyed() {
            clearInterval(this.timer)
          },
          tick() {
            const started = parseInt(this.el.dataset.startedAt, 10)
            const expectedMin = parseInt(this.el.dataset.expectedMinutes, 10)
            const elapsed = Math.max(0, Math.floor(Date.now() / 1000) - started)
            const m = Math.floor(elapsed / 60)
            const s = String(elapsed % 60).padStart(2, "0")
            this.el.textContent = `${m}:${s}`
            const ticket = this.el.closest("[data-kds-ticket]")
            if (ticket) ticket.classList.toggle("kds-overdue", elapsed > expectedMin * 60)
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".KdsSound">
        export default {
          mounted() {
            this.enabled = localStorage.getItem("kds-sound") !== "off"
            this.render()
            this.el.addEventListener("click", () => {
              this.enabled = !this.enabled
              localStorage.setItem("kds-sound", this.enabled ? "on" : "off")
              this.render()
            })
            this.handleEvent("kds:new-ticket", () => this.enabled && this.beep())
          },
          render() {
            this.el.querySelector("[data-sound-on]").classList.toggle("hidden", !this.enabled)
            this.el.querySelector("[data-sound-on]").classList.toggle("flex", this.enabled)
            this.el.querySelector("[data-sound-off]").classList.toggle("hidden", this.enabled)
            this.el.querySelector("[data-sound-off]").classList.toggle("flex", !this.enabled)
          },
          beep() {
            // Two quick rising tones via WebAudio — no audio asset to
            // fetch, works offline on the kitchen tablet.
            try {
              this.audioCtx = this.audioCtx || new AudioContext()
              const ctx = this.audioCtx
              const osc = ctx.createOscillator()
              const gain = ctx.createGain()
              osc.connect(gain)
              gain.connect(ctx.destination)
              osc.frequency.setValueAtTime(660, ctx.currentTime)
              osc.frequency.setValueAtTime(880, ctx.currentTime + 0.15)
              gain.gain.setValueAtTime(0.25, ctx.currentTime)
              gain.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.4)
              osc.start()
              osc.stop(ctx.currentTime + 0.4)
            } catch (_e) {}
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".KdsReload">
        export default {
          mounted() {
            const loadedAt = Date.now()
            const twelveHours = 12 * 60 * 60 * 1000
            this.timer = setInterval(() => {
              if (Date.now() - loadedAt > twelveHours) {
                this.el.classList.remove("hidden")
                this.el.classList.add("flex")
              }
            }, 10 * 60 * 1000)
            this.el.querySelector("[data-reload]").addEventListener("click", () => window.location.reload())
          },
          destroyed() {
            clearInterval(this.timer)
          }
        }
      </script>
    </Layouts.kds>
    """
  end

  attr :title, :string, required: true
  attr :count, :integer, required: true
  attr :accent, :string, required: true
  attr :stream_id, :string, required: true
  attr :stream, :any, required: true
  attr :empty, :string, required: true

  defp kds_column(assigns) do
    ~H"""
    <section class="flex flex-col min-h-0 rounded-box bg-base-100/40">
      <div class="flex-none flex items-center justify-between px-3 pt-3">
        <h2 class={["text-sm font-bold uppercase tracking-wide", @accent]}>{@title}</h2>
        <span class="badge badge-sm badge-ghost tabular-nums">{@count}</span>
      </div>
      <div id={@stream_id} phx-update="stream" class="flex-1 min-h-0 overflow-y-auto space-y-3 p-3">
        <p
          id={"#{@stream_id}-empty"}
          class="hidden only:block text-sm text-base-content/40 text-center py-8"
        >
          {@empty}
        </p>
        <.kds_ticket :for={{id, order} <- @stream} id={id} order={order} />
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :order, :any, required: true

  defp kds_ticket(assigns) do
    ~H"""
    <div
      id={@id}
      data-kds-ticket
      class={[
        "rounded-box bg-base-100 shadow-sm border-s-[6px] overflow-hidden",
        "motion-safe:animate-[kds-ticket-in_250ms_ease-out]",
        status_border(@order.status)
      ]}
    >
      <div class="kds-ticket-header flex items-start justify-between gap-2 px-3 py-2">
        <div class="flex items-center gap-2 flex-wrap min-w-0">
          <span class="text-lg font-extrabold">#{@order.number}</span>
          <span :if={@order.table} class="badge badge-outline badge-sm font-semibold">
            {gettext("Table %{number}", number: @order.table.number)}
          </span>
          <span :if={!@order.table} class="badge badge-outline badge-sm font-semibold">
            {kind_label(@order.kind)}
          </span>
          <span
            :if={@order.flag == :contains_86d_item}
            class="badge badge-warning badge-sm font-semibold"
          >
            ⚠ {gettext("contains 86'd item")}
          </span>
        </div>
        <div class="flex items-center gap-1 shrink-0">
          <button
            :if={@order.status in [:preparing, :ready]}
            type="button"
            phx-click="undo"
            phx-value-id={@order.id}
            class="btn btn-ghost btn-xs px-1.5"
            aria-label={gettext("Undo — one step back")}
          >
            <.icon name="hero-arrow-uturn-left" class="size-4" />
          </button>
          <span
            id={"timer-#{@id}"}
            phx-hook=".TicketTimer"
            phx-update="ignore"
            data-started-at={DateTime.to_unix(@order.placed_at)}
            data-expected-minutes={Ordering.expected_prep_minutes(@order)}
            class={[
              "kds-ticket-timer text-[22px] font-extrabold tabular-nums",
              timer_color(@order.status)
            ]}
          >
            {initial_elapsed(@order)}
          </span>
        </div>
      </div>

      <div class="px-3 pb-3 divide-y divide-base-200">
        <div :for={item <- @order.items} class="py-1.5">
          <p class="text-lg font-semibold leading-snug">{item.qty}× {item.name_snapshot}</p>
          <p :for={mod <- item.modifiers} class="ps-4 text-base text-base-content/70 leading-snug">
            {mod.name_snapshot}
          </p>
          <p :if={item.notes} class="ps-4 text-base text-warning leading-snug">"{item.notes}"</p>
        </div>
        <p :if={@order.notes} class="pt-2 text-base text-warning font-medium">
          {gettext("Note:")} "{@order.notes}"
        </p>
      </div>

      <button
        :if={@order.status in [:placed, :accepted]}
        type="button"
        phx-click="start"
        phx-value-id={@order.id}
        class="h-14 w-full text-lg font-bold text-white bg-status-preparing/90 hover:bg-status-preparing"
      >
        {gettext("Start")}
      </button>
      <button
        :if={@order.status == :preparing}
        type="button"
        phx-click="mark_ready"
        phx-value-id={@order.id}
        class="h-14 w-full text-lg font-bold text-white bg-success/90 hover:bg-success"
      >
        {gettext("Ready")}
      </button>
      <div
        :if={@order.status == :ready}
        class="h-14 w-full flex items-center justify-center text-base font-semibold text-success"
      >
        {gettext("Waiting for pickup")}
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{scope.venue.id}:orders")
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Kitchen"))
     |> assign(:hide_utility_bar, true)
     |> load_board()}
  end

  @impl true
  def handle_event("start", %{"id" => id}, socket),
    do: act(socket, id, &Ordering.kitchen_start_order/2)

  def handle_event("mark_ready", %{"id" => id}, socket),
    do: act(socket, id, &Ordering.kitchen_mark_ready/2)

  def handle_event("undo", %{"id" => id}, socket),
    do: act(socket, id, &Ordering.kitchen_undo/2)

  # This tablet's own taps come back through the same broadcast as
  # everyone else's — the success path changes nothing locally, so
  # there's exactly one update path to get right.
  defp act(socket, id, fun) do
    scope = socket.assigns.current_scope

    result =
      case Ordering.get_kitchen_order(scope, id) do
        nil -> {:error, :stale}
        order -> fun.(scope, order)
      end

    case result do
      {:ok, _order} ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That ticket moved on — board refreshed."))
         |> load_board()}
    end
  end

  @impl true
  def handle_info({:order_updated, order_id}, socket) do
    order = Ordering.get_kitchen_order(socket.assigns.current_scope, order_id)
    {:noreply, apply_update(socket, order_id, order)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Gone from the kitchen's world (served, cancelled, refunded, another
  # venue's noise) — drop the ticket if we were showing it.
  defp apply_update(socket, order_id, nil) do
    case Map.get(socket.assigns.column_index, order_id) do
      nil ->
        socket

      column ->
        socket
        |> stream_delete_by_dom_id(stream_name(column), dom_id(column, order_id))
        |> set_column(order_id, nil)
    end
  end

  defp apply_update(socket, order_id, order) do
    new_column = column_for(order.status)

    case Map.get(socket.assigns.column_index, order_id) do
      # Brand-new ticket — the sound cue moment (ui-rules.md "new
      # tickets appear instantly with sound cue").
      nil ->
        socket
        |> stream_insert(stream_name(new_column), order)
        |> set_column(order_id, new_column)
        |> push_event("kds:new-ticket", %{})

      # Same column (a flag change, an item edit) — in-place patch.
      ^new_column ->
        stream_insert(socket, stream_name(new_column), order)

      old_column ->
        socket
        |> stream_delete_by_dom_id(stream_name(old_column), dom_id(old_column, order_id))
        |> stream_insert(stream_name(new_column), order)
        |> set_column(order_id, new_column)
    end
  end

  defp load_board(socket) do
    orders = Ordering.list_kitchen_orders(socket.assigns.current_scope)
    index = Map.new(orders, &{&1.id, column_for(&1.status)})

    socket
    |> assign(:column_index, index)
    |> assign_counts()
    |> stream(:new_orders, of_column(orders, :new), reset: true)
    |> stream(:preparing_orders, of_column(orders, :preparing), reset: true)
    |> stream(:ready_orders, of_column(orders, :ready), reset: true)
  end

  defp of_column(orders, column), do: Enum.filter(orders, &(column_for(&1.status) == column))

  defp set_column(socket, order_id, nil) do
    socket
    |> update(:column_index, &Map.delete(&1, order_id))
    |> assign_counts()
  end

  defp set_column(socket, order_id, column) do
    socket
    |> update(:column_index, &Map.put(&1, order_id, column))
    |> assign_counts()
  end

  defp assign_counts(socket) do
    frequencies = socket.assigns.column_index |> Map.values() |> Enum.frequencies()

    assign(socket, :counts, %{
      new: Map.get(frequencies, :new, 0),
      preparing: Map.get(frequencies, :preparing, 0),
      ready: Map.get(frequencies, :ready, 0)
    })
  end

  defp column_for(status) when status in [:placed, :accepted], do: :new
  defp column_for(:preparing), do: :preparing
  defp column_for(:ready), do: :ready

  defp stream_name(:new), do: :new_orders
  defp stream_name(:preparing), do: :preparing_orders
  defp stream_name(:ready), do: :ready_orders

  # Streams' default DOM ids are "#{stream_name}-#{id}" — recomputed here
  # for targeted deletes out of whichever column a ticket last lived in.
  defp dom_id(column, order_id), do: "#{stream_name(column)}-#{order_id}"

  defp status_border(:placed), do: "border-status-placed"
  defp status_border(:accepted), do: "border-info"
  defp status_border(:preparing), do: "border-status-preparing"
  defp status_border(:ready), do: "border-success"

  defp timer_color(:placed), do: "text-status-placed"
  defp timer_color(:accepted), do: "text-info"
  defp timer_color(:preparing), do: "text-status-preparing"
  defp timer_color(:ready), do: "text-success"

  # Server-rendered first paint only — the `.TicketTimer` hook takes over
  # on mount and ticks client-side from `data-started-at`.
  defp initial_elapsed(order) do
    elapsed = max(DateTime.diff(DateTime.utc_now(), order.placed_at), 0)
    minutes = div(elapsed, 60)
    seconds = elapsed |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{minutes}:#{seconds}"
  end

  defp kind_label(:takeaway), do: gettext("Takeaway")
  defp kind_label(:counter), do: gettext("Counter")
  defp kind_label(_kind), do: gettext("Dine in")
end

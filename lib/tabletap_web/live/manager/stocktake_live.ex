defmodule TabletapWeb.Manager.StocktakeLive do
  @moduledoc """
  Physical-count stocktake (build-plan.md Feature 13, design-qa.md
  Q14/Q43): start a session (snapshots every ingredient's theoretical
  stock), enter physical counts, close to reconcile stock with a real
  `:adjustment` movement per counted line and show the variance report
  (counted vs the snapshot, valued at cost). Only one session open at a
  time per venue.
  """
  use TabletapWeb, :live_view

  alias Tabletap.{Inventory, Ordering, Tenants}
  alias Tabletap.Inventory.UnitInput

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:inventory}
      venues={@venues}
    >
      <div class="mb-2">
        <.link navigate={~p"/inventory"} class="text-sm text-base-content/60 hover:underline">
          <.icon name="hero-arrow-left" class="size-3" /> {gettext("Inventory")}
        </.link>
        <h1 class="text-2xl font-bold">{gettext("Stocktake")}</h1>
      </div>

      <div
        :if={!@session && !@variance_report}
        class="rounded-box bg-base-100 border border-base-300 p-6"
      >
        <p class="text-sm text-base-content/70 mb-3">
          {gettext(
            "Snapshots every ingredient's current stock, then lets you enter physical counts. Best done at close, with the fewest sales in flight."
          )}
        </p>
        <p :if={@open_orders_count > 0} class="text-sm text-warning mb-3 flex items-center gap-2">
          <.icon name="hero-exclamation-triangle" class="size-4" />
          {ngettext(
            "%{count} order still open — counting now may not match sales in progress.",
            "%{count} orders still open — counting now may not match sales in progress.",
            @open_orders_count,
            count: @open_orders_count
          )}
        </p>
        <button type="button" phx-click="start_stocktake" class="btn btn-primary btn-sm">
          {gettext("Start stocktake")}
        </button>
      </div>

      <div :if={@session} class="space-y-3">
        <div class="flex items-center justify-between flex-wrap gap-3">
          <p class="text-sm text-base-content/60">
            {gettext("Started %{time}",
              time: Calendar.strftime(@session.inserted_at, "%Y-%m-%d %H:%M")
            )}
          </p>
          <button
            type="button"
            phx-click="close_stocktake"
            data-confirm={
              gettext("Close this stocktake? Every counted line reconciles stock immediately.")
            }
            class="btn btn-primary btn-sm"
          >
            {gettext("Close & reconcile")}
          </button>
        </div>

        <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
          <table class="table">
            <thead>
              <tr>
                <th>{gettext("Ingredient")}</th>
                <th>{gettext("Counted")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={line <- @lines} id={"stocktake-line-#{line.id}"}>
                <td class="font-medium">{line.ingredient.name}</td>
                <td>
                  <form
                    phx-submit="save_count"
                    phx-value-line-id={line.id}
                    class="flex items-center gap-2"
                  >
                    <input
                      type="text"
                      name="counted_qty"
                      value={line.counted_qty && Decimal.to_string(line.counted_qty)}
                      placeholder={gettext("e.g. 2kg")}
                      class="input input-sm w-32"
                    />
                    <span class="text-xs text-base-content/50">{line.ingredient.unit}</span>
                    <button type="submit" class="btn btn-xs btn-outline">{gettext("Set")}</button>
                    <.icon
                      :if={line.counted_qty}
                      name="hero-check-circle"
                      class="size-4 text-success"
                    />
                  </form>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div :if={@variance_report} class="mt-6">
        <h2 class="font-semibold mb-3">{gettext("Variance report")}</h2>
        <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
          <table class="table">
            <thead>
              <tr>
                <th>{gettext("Ingredient")}</th>
                <th>{gettext("Theoretical")}</th>
                <th>{gettext("Counted")}</th>
                <th>{gettext("Variance")}</th>
                <th>{gettext("Value")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @variance_report}>
                <td class="font-medium">{row.ingredient.name}</td>
                <td class="tabular-nums">
                  {Decimal.to_string(row.theoretical)} {row.ingredient.unit}
                </td>
                <td class="tabular-nums">{Decimal.to_string(row.counted)} {row.ingredient.unit}</td>
                <td class={[
                  "tabular-nums font-semibold",
                  Decimal.negative?(row.variance) && "text-error"
                ]}>
                  {Decimal.to_string(row.variance)} {row.ingredient.unit}
                </td>
                <td class="tabular-nums">
                  <.money :if={row.value} amount={row.value} />
                  <span :if={!row.value} class="text-base-content/40">—</span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p :if={@variance_report == []} class="text-sm text-base-content/50 mt-3">
          {gettext("Nothing was counted this session.")}
        </p>
      </div>
    </Layouts.manager>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    session = Inventory.get_open_stocktake(scope)

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:venues, Tenants.list_venues(scope))
     |> assign(:session, session)
     |> assign(:lines, lines_for(scope, session))
     |> assign(:variance_report, nil)
     |> assign(:open_orders_count, Ordering.count_open_orders(scope))}
  end

  @impl true
  def handle_event("start_stocktake", _params, socket) do
    scope = socket.assigns.current_scope

    case Inventory.start_stocktake(scope) do
      {:ok, session} ->
        {:noreply,
         socket
         |> assign(:session, session)
         |> assign(:lines, lines_for(scope, session))
         |> assign(:variance_report, nil)}

      {:error, :already_open} ->
        {:noreply, put_flash(socket, :error, gettext("A stocktake is already open."))}
    end
  end

  def handle_event("save_count", %{"line-id" => line_id, "counted_qty" => qty_str}, socket) do
    scope = socket.assigns.current_scope
    line = Enum.find(socket.assigns.lines, &(&1.id == line_id))

    case UnitInput.parse(line.ingredient.unit, qty_str) do
      {:ok, qty} ->
        {:ok, _} = Inventory.record_count(scope, line, qty)
        {:noreply, assign(socket, :lines, lines_for(scope, socket.assigns.session))}

      :error ->
        {:noreply,
         put_flash(socket, :error, gettext("Enter a valid quantity, e.g. 2kg or 500g."))}
    end
  end

  def handle_event("close_stocktake", _params, socket) do
    scope = socket.assigns.current_scope

    {:ok, _session, variance_report} = Inventory.close_stocktake(scope, socket.assigns.session)

    {:noreply,
     socket
     |> assign(:session, nil)
     |> assign(:lines, [])
     |> assign(:variance_report, variance_report)
     |> assign(:open_orders_count, Ordering.count_open_orders(scope))
     |> put_flash(:info, gettext("Stocktake closed and reconciled."))}
  end

  defp lines_for(_scope, nil), do: []
  defp lines_for(scope, session), do: Inventory.list_stocktake_lines(scope, session)
end

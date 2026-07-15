defmodule TabletapWeb.Manager.RestockReportLive do
  @moduledoc """
  The restock report (build-plan.md Feature 13): every ingredient at or
  below its threshold, with a suggested reorder quantity, a CSV export,
  and a link to the printable purchase-order sheet — all three read
  `Inventory.restock_report/1` so they never disagree with each other.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Inventory
  alias Tabletap.Tenants

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:inventory}
      venues={@venues}
    >
      <div class="flex items-center justify-between flex-wrap gap-4 mb-2">
        <div>
          <.link navigate={~p"/inventory"} class="text-sm text-base-content/60 hover:underline">
            <.icon name="hero-arrow-left" class="size-3" /> {gettext("Inventory")}
          </.link>
          <h1 class="text-2xl font-bold">{gettext("Restock report")}</h1>
        </div>
        <div :if={@rows != []} class="flex items-center gap-2">
          <.link navigate={~p"/inventory/restock/print"} class="btn btn-outline btn-sm">
            <.icon name="hero-printer" class="size-4" /> {gettext("Print purchase order")}
          </.link>
          <a href={~p"/inventory/restock.csv"} class="btn btn-outline btn-sm">
            <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export CSV")}
          </a>
        </div>
      </div>
      <p class="text-sm text-base-content/60 mb-6 max-w-prose">
        {gettext(
          "Everything at or below its threshold, with a suggested reorder quantity (threshold × 2 − current)."
        )}
      </p>

      <div :if={@rows == []} class="rounded-box bg-base-100 border border-base-300 p-6 text-center">
        <.icon name="hero-check-circle" class="size-8 mx-auto text-success" />
        <p class="mt-2 font-medium">{gettext("Nothing needs restocking right now.")}</p>
      </div>

      <div :if={@rows != []} class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
        <table class="table">
          <thead>
            <tr>
              <th>{gettext("Ingredient")}</th>
              <th>{gettext("Current")}</th>
              <th>{gettext("Threshold")}</th>
              <th>{gettext("Suggested reorder")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} id={"restock-row-#{row.ingredient.id}"}>
              <td class="font-medium">{row.ingredient.name}</td>
              <td class="tabular-nums">{qty_label(row.current, row.ingredient.unit)}</td>
              <td class="tabular-nums">{qty_label(row.threshold, row.ingredient.unit)}</td>
              <td class="tabular-nums font-semibold">
                {qty_label(row.suggested, row.ingredient.unit)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.manager>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:venues, Tenants.list_venues(scope))
     |> assign(:rows, Inventory.restock_report(scope))}
  end

  defp qty_label(qty, unit), do: "#{Decimal.to_string(qty)} #{unit}"
end

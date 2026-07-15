defmodule TabletapWeb.Manager.RestockPrintLive do
  @moduledoc """
  Printable, supplier-ready purchase-order sheet (build-plan.md Feature
  13) — same table `Manager.RestockReportLive` shows on screen, laid out
  for paper. Screen chrome is `print:hidden`, print CSS/hook pattern
  mirrors `Manager.TablePrintLive` exactly.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Inventory

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-white text-black">
      <div class="print:hidden border-b border-base-300 px-4 py-3 flex items-center justify-between gap-3 flex-wrap">
        <.link navigate={~p"/inventory/restock"} class="btn btn-ghost btn-sm">
          <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to restock report")}
        </.link>
        <button id="print-po" phx-hook=".Print" type="button" class="btn btn-primary btn-sm">
          <.icon name="hero-printer" class="size-4" /> {gettext("Print")}
        </button>
      </div>

      <div class="p-6 print:p-8 max-w-3xl mx-auto">
        <div class="flex items-center justify-between mb-6">
          <div>
            <p class="text-xl font-extrabold">{@venue.name}</p>
            <p class="text-sm text-black/60">{gettext("Purchase order")}</p>
          </div>
          <p class="text-sm text-black/60">{Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d")}</p>
        </div>

        <table class="w-full text-sm border-collapse">
          <thead>
            <tr class="border-b-2 border-black/20 text-left">
              <th class="py-2">{gettext("Ingredient")}</th>
              <th class="py-2">{gettext("Current")}</th>
              <th class="py-2">{gettext("Threshold")}</th>
              <th class="py-2">{gettext("Order qty")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} class="border-b border-black/10">
              <td class="py-2 font-medium">{row.ingredient.name}</td>
              <td class="py-2 tabular-nums">{qty_label(row.current, row.ingredient.unit)}</td>
              <td class="py-2 tabular-nums">{qty_label(row.threshold, row.ingredient.unit)}</td>
              <td class="py-2 tabular-nums font-semibold">
                {qty_label(row.suggested, row.ingredient.unit)}
              </td>
            </tr>
          </tbody>
        </table>

        <p :if={@rows == []} class="text-center text-black/50 py-12">
          {gettext("Nothing needs restocking right now.")}
        </p>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Print">
      export default {
        mounted() {
          this.el.addEventListener("click", () => window.print())
        }
      }
    </script>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:venue, scope.venue)
     |> assign(:rows, Inventory.restock_report(scope))}
  end

  defp qty_label(qty, unit), do: "#{Decimal.to_string(qty)} #{unit}"
end

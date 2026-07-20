defmodule TabletapWeb.Manager.Analytics.InventoryCostLive do
  @moduledoc """
  Owner-dashboard.md Screen 6 — Inventory & Cost (build-plan.md Feature
  18). Reads `Tabletap.Analytics.inventory_cost_summary/3`: food cost %
  for the period (the industry's #1 profitability KPI, healthy ≈
  28-35%), current stock on hand (valued, low-stock flagged), usage
  trend, wastage by reason, restock purchase history, and stocktake
  variance history. The restock report itself (current/threshold/
  suggested reorder + CSV + printable PO sheet) already exists at
  `/inventory/restock` (Feature 13) — this screen links to it rather
  than rebuilding it.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Analytics
  alias Tabletap.Tenants

  @ranges ~w(7d 30d 90d)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:analytics_inventory_cost}
      venues={@venues}
    >
      <div class="flex items-center justify-between flex-wrap gap-4 mb-6">
        <h1 class="text-2xl font-bold">{gettext("Inventory & Cost")}</h1>
        <div class="flex items-center gap-2">
          <.range_picker range={@range} />
          <.link navigate={~p"/inventory/restock"} class="btn btn-sm btn-outline">
            {gettext("Restock report")} <.icon name="hero-arrow-top-right-on-square" class="size-3" />
          </.link>
        </div>
      </div>

      <div class="rounded-box border border-base-300 bg-base-100 p-4 mb-6">
        <p class="text-xs font-medium text-base-content/60">{gettext("Food cost %")}</p>
        <p class="mt-1 text-2xl font-bold tabular-nums">
          {if @summary.food_cost_pct, do: "#{Decimal.round(@summary.food_cost_pct, 1)}%", else: "—"}
        </p>
        <p class="text-xs text-base-content/50 mt-0.5">
          {gettext("healthy is roughly 28-35% — ")}<.money
            amount={@summary.food_cost}
            locale={@locale}
          />
          {gettext("ingredient cost consumed this period")}
        </p>
      </div>

      <div class="rounded-box border border-base-300 bg-base-100 p-4 mb-6 overflow-x-auto">
        <h2 class="font-semibold mb-3">{gettext("Stock on hand")}</h2>
        <p :if={@summary.stock_on_hand == []} class="text-sm text-base-content/50">
          {gettext("No ingredients yet.")}
        </p>
        <table :if={@summary.stock_on_hand != []} class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("Ingredient")}</th>
              <th>{gettext("Qty")}</th>
              <th>{gettext("Value")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @summary.stock_on_hand} class={row.low_stock && "text-warning"}>
              <td class="font-medium">
                {row.name}
                <.icon :if={row.low_stock} name="hero-exclamation-triangle" class="size-3 inline" />
              </td>
              <td class="tabular-nums">{Decimal.round(row.stock_qty, 1)} {row.unit}</td>
              <td class="tabular-nums"><.money amount={row.value} locale={@locale} /></td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="grid gap-6 lg:grid-cols-2 mb-6">
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="font-semibold mb-3">{gettext("Usage trend")}</h2>
          <p :if={@summary.usage_trend == []} class="text-sm text-base-content/50">
            {gettext("No consumption yet.")}
          </p>
          <ul :if={@summary.usage_trend != []} class="text-sm space-y-1.5">
            <li :for={row <- @summary.usage_trend} class="flex items-center justify-between">
              <span class="truncate">{row.name}</span>
              <span class="tabular-nums shrink-0 ml-2">
                {Decimal.round(row.qty, 1)} {row.unit} · {row.cost && format_money(row.cost, @locale)}
              </span>
            </li>
          </ul>
        </div>

        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="font-semibold mb-3">{gettext("Wastage by reason")}</h2>
          <p :if={@summary.wastage == []} class="text-sm text-base-content/50">
            {gettext("No logged wastage this period.")}
          </p>
          <ul :if={@summary.wastage != []} class="text-sm space-y-1.5">
            <li :for={row <- @summary.wastage} class="flex items-center justify-between">
              <span class="truncate">{row.reason}</span>
              <span class="tabular-nums shrink-0 ml-2"><.money amount={row.cost} locale={@locale} /></span>
            </li>
          </ul>
        </div>
      </div>

      <div class="grid gap-6 lg:grid-cols-2">
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="font-semibold mb-3">{gettext("Purchase history")}</h2>
          <p :if={@summary.purchases == []} class="text-sm text-base-content/50">
            {gettext("No restocks this period.")}
          </p>
          <ul :if={@summary.purchases != []} class="text-sm space-y-1.5">
            <li :for={row <- @summary.purchases} class="flex items-center justify-between">
              <span class="truncate">
                {row.ingredient_name} · {Decimal.round(row.qty, 1)} {row.unit}
              </span>
              <span class="tabular-nums shrink-0 ml-2"><.money
                amount={row.unit_cost}
                locale={@locale}
              /></span>
            </li>
          </ul>
        </div>

        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="font-semibold mb-1">{gettext("Stocktake variance")}</h2>
          <p class="text-xs text-base-content/50 mb-3">
            {gettext("Actual vs theoretical — reveals over-portioning, waste, or theft.")}
          </p>
          <p :if={@variance_with_names == []} class="text-sm text-base-content/50">
            {gettext("No closed stocktakes this period.")}
          </p>
          <ul :if={@variance_with_names != []} class="text-sm space-y-1.5">
            <li :for={row <- @variance_with_names} class="flex items-center justify-between">
              <span class="truncate">{row.name}</span>
              <span class="tabular-nums shrink-0 ml-2">
                {Decimal.round(row.variance, 1)} {row.unit} {row.value &&
                  ["(", format_money(row.value, @locale), ")"]}
              </span>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.manager>
    """
  end

  attr :range, :string, required: true

  defp range_picker(assigns) do
    ~H"""
    <div class="join">
      <.link
        patch={~p"/analytics/inventory-cost?#{[range: "7d"]}"}
        class={["btn btn-sm join-item", @range == "7d" && "btn-primary"]}
      >
        {gettext("7d")}
      </.link>
      <.link
        patch={~p"/analytics/inventory-cost?#{[range: "30d"]}"}
        class={["btn btn-sm join-item", @range == "30d" && "btn-primary"]}
      >
        {gettext("30d")}
      </.link>
      <.link
        patch={~p"/analytics/inventory-cost?#{[range: "90d"]}"}
        class={["btn btn-sm join-item", @range == "90d" && "btn-primary"]}
      >
        {gettext("90d")}
      </.link>
    </div>
    """
  end

  ## Mount / params

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:venues, Tenants.list_venues(scope))
     |> assign(:locale, scope.venue.locale)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope
    range = if params["range"] in @ranges, do: params["range"], else: "30d"
    {from_date, to_date} = range_dates(scope.venue, range)

    summary = Analytics.inventory_cost_summary(scope, from_date, to_date)
    ingredient_names = Map.new(summary.stock_on_hand, &{&1.ingredient_id, {&1.name, &1.unit}})

    variance_with_names =
      Enum.map(summary.variance, fn row ->
        {name, unit} = Map.get(ingredient_names, row.ingredient_id, {"—", nil})
        Map.merge(row, %{name: name, unit: unit})
      end)

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:summary, summary)
     |> assign(:variance_with_names, variance_with_names)}
  end

  defp range_dates(venue, "7d") do
    today = Tenants.business_date(venue)
    {Date.add(today, -6), today}
  end

  defp range_dates(venue, "90d") do
    today = Tenants.business_date(venue)
    {Date.add(today, -89), today}
  end

  defp range_dates(venue, _thirty_day) do
    today = Tenants.business_date(venue)
    {Date.add(today, -29), today}
  end
end

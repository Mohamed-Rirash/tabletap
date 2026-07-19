defmodule TabletapWeb.Manager.Analytics.MenuPerformanceLive do
  @moduledoc """
  Owner-dashboard.md Screen 3 — Menu Performance (build-plan.md Feature
  18). Sortable per-item table (sold, revenue, food cost, margin,
  rating, sellout days) plus the classic BCG-style menu-engineering
  quadrant, top/bottom 10, and a category-mix breakdown — all from
  `Tabletap.Analytics.menu_performance/3` (which itself reads
  `range_summary/3`'s own `items_sold` jsonb, never a second raw-order
  query).

  Modifier attach rate and average sellout time (both asked for in
  owner-dashboard.md) aren't rendered — neither is derivable from the
  current schema (no modifier dimension in `items_sold`, no timestamp
  recorded for "when did this hit its limit"), documented in
  `Tabletap.Analytics`'s own moduledoc rather than silently guessed at.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Analytics
  alias Tabletap.Tenants

  @ranges ~w(today 7d 30d)
  @sort_fields ~w(sold revenue food_cost margin margin_pct rating sellout_days)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:analytics_menu_performance}
      venues={@venues}
    >
      <div class="flex items-center justify-between flex-wrap gap-4 mb-6">
        <h1 class="text-2xl font-bold">{gettext("Menu Performance")}</h1>
        <div class="flex items-center gap-2">
          <.range_picker range={@range} />
          <a
            href={
              ~p"/analytics/menu-performance.csv?#{[from: Date.to_string(@from_date), to: Date.to_string(@to_date)]}"
            }
            class="btn btn-sm btn-outline"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export CSV")}
          </a>
        </div>
      </div>

      <.quadrant_grid quadrant={@quadrant} locale={@locale} />

      <div class="rounded-box border border-base-300 bg-base-100 p-4 mt-6 overflow-x-auto">
        <h2 class="font-semibold mb-3">{gettext("All items")}</h2>
        <table class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("Item")}</th>
              <.sort_th field="sold" sort={@sort} label={gettext("Sold")} />
              <.sort_th field="revenue" sort={@sort} label={gettext("Revenue")} />
              <.sort_th field="food_cost" sort={@sort} label={gettext("Food cost")} />
              <.sort_th field="margin" sort={@sort} label={gettext("Margin")} />
              <.sort_th field="margin_pct" sort={@sort} label={gettext("Margin %")} />
              <.sort_th field="rating" sort={@sort} label={gettext("Rating")} />
              <.sort_th field="sellout_days" sort={@sort} label={gettext("Sellout days")} />
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @sorted_rows} id={"item-#{row.menu_item_id}"}>
              <td class="font-medium">{row.name}</td>
              <td class="tabular-nums">{row.sold}</td>
              <td class="tabular-nums"><.money amount={row.revenue} locale={@locale} /></td>
              <td class="tabular-nums"><.money amount={row.food_cost} locale={@locale} /></td>
              <td class="tabular-nums"><.money amount={row.margin} locale={@locale} /></td>
              <td class="tabular-nums">{margin_pct_label(row.margin_pct)}</td>
              <td class="tabular-nums">{rating_label(row.rating)}</td>
              <td class="tabular-nums">{row.sellout_days}</td>
            </tr>
            <tr :if={@sorted_rows == []}>
              <td colspan="8" class="text-center text-base-content/50 py-6">
                {gettext("No items sold in this period.")}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="grid gap-6 lg:grid-cols-2 mt-6">
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="font-semibold mb-3">{gettext("Top 10 by revenue")}</h2>
          <.ranked_list rows={Enum.take(@rows_by_revenue, 10)} locale={@locale} />
        </div>
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="font-semibold mb-3">{gettext("Bottom 10 by revenue")}</h2>
          <.ranked_list rows={Enum.take(Enum.reverse(@rows_by_revenue), 10)} locale={@locale} />
        </div>
      </div>

      <div class="rounded-box border border-base-300 bg-base-100 p-4 mt-6">
        <h2 class="font-semibold mb-3">{gettext("Category mix")}</h2>
        <p :if={@category_mix == %{}} class="text-sm text-base-content/50">
          {gettext("No data yet.")}
        </p>
        <dl :if={@category_mix != %{}} class="space-y-2 text-sm">
          <div
            :for={{category, amount} <- sorted_category_mix(@category_mix)}
            class="flex items-center justify-between"
          >
            <dt class="text-base-content/70">{category}</dt>
            <dd class="font-semibold"><.money amount={amount} locale={@locale} /></dd>
          </div>
        </dl>
      </div>
    </Layouts.manager>
    """
  end

  attr :range, :string, required: true

  defp range_picker(assigns) do
    ~H"""
    <div class="join">
      <.link
        patch={~p"/analytics/menu-performance?#{[range: "today"]}"}
        class={["btn btn-sm join-item", @range == "today" && "btn-primary"]}
      >
        {gettext("Today")}
      </.link>
      <.link
        patch={~p"/analytics/menu-performance?#{[range: "7d"]}"}
        class={["btn btn-sm join-item", @range == "7d" && "btn-primary"]}
      >
        {gettext("7d")}
      </.link>
      <.link
        patch={~p"/analytics/menu-performance?#{[range: "30d"]}"}
        class={["btn btn-sm join-item", @range == "30d" && "btn-primary"]}
      >
        {gettext("30d")}
      </.link>
    </div>
    """
  end

  attr :quadrant, :map, required: true
  attr :locale, :string, required: true

  defp quadrant_grid(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-3">
      <.quadrant_cell
        title={gettext("Stars")}
        hint={gettext("high volume, high margin — feature them, never 86 them")}
        items={@quadrant.stars}
        class="bg-success/10 border-success/30"
      />
      <.quadrant_cell
        title={gettext("Puzzles")}
        hint={gettext("low volume, high margin — better photo, better placement")}
        items={@quadrant.puzzles}
        class="bg-info/10 border-info/30"
      />
      <.quadrant_cell
        title={gettext("Plowhorses")}
        hint={gettext("high volume, low margin — raise price or cut recipe cost")}
        items={@quadrant.plowhorses}
        class="bg-warning/10 border-warning/30"
      />
      <.quadrant_cell
        title={gettext("Dogs")}
        hint={gettext("low volume, low margin — candidates to remove")}
        items={@quadrant.dogs}
        class="bg-error/10 border-error/30"
      />
    </div>
    """
  end

  attr :title, :string, required: true
  attr :hint, :string, required: true
  attr :items, :list, required: true
  attr :class, :string, required: true

  defp quadrant_cell(assigns) do
    ~H"""
    <div class={["rounded-box border p-4", @class]}>
      <h3 class="font-semibold">{@title}</h3>
      <p class="text-xs text-base-content/60 mb-2">{@hint}</p>
      <p :if={@items == []} class="text-sm text-base-content/40">{gettext("None yet")}</p>
      <ul :if={@items != []} class="text-sm space-y-0.5">
        <li :for={item <- @items}>{item.name}</li>
      </ul>
    </div>
    """
  end

  attr :field, :string, required: true
  attr :sort, :string, required: true
  attr :label, :string, required: true

  defp sort_th(assigns) do
    ~H"""
    <th>
      <.link patch={~p"/analytics/menu-performance?#{[sort: @field]}"} class="flex items-center gap-1">
        {@label}
        <.icon :if={@sort == @field} name="hero-chevron-down" class="size-3" />
      </.link>
    </th>
    """
  end

  attr :rows, :list, required: true
  attr :locale, :string, required: true

  defp ranked_list(assigns) do
    ~H"""
    <p :if={@rows == []} class="text-sm text-base-content/50">{gettext("No data yet.")}</p>
    <ol :if={@rows != []} class="text-sm space-y-1 list-decimal list-inside">
      <li :for={row <- @rows} class="flex items-center justify-between gap-2">
        <span class="truncate">{row.name}</span>
        <span class="tabular-nums shrink-0"><.money amount={row.revenue} locale={@locale} /></span>
      </li>
    </ol>
    """
  end

  defp margin_pct_label(nil), do: "—"
  defp margin_pct_label(pct), do: "#{Decimal.round(pct, 1)}%"

  defp rating_label(nil), do: "—"
  defp rating_label(%{avg: avg, count: count}), do: "#{Decimal.round(avg, 1)} (#{count})"

  defp sorted_category_mix(mix),
    do: Enum.sort_by(mix, fn {_cat, amount} -> amount end, {:desc, Money})

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

    range =
      if params["range"] in @ranges, do: params["range"], else: socket.assigns[:range] || "7d"

    sort =
      if params["sort"] in @sort_fields,
        do: params["sort"],
        else: socket.assigns[:sort] || "revenue"

    {from_date, to_date} = range_dates(scope.venue, range)

    rows = Analytics.menu_performance(scope, from_date, to_date)

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:sort, sort)
     |> assign(:from_date, from_date)
     |> assign(:to_date, to_date)
     |> assign(:rows_by_revenue, Enum.sort_by(rows, & &1.revenue, {:desc, Money}))
     |> assign(:sorted_rows, sort_rows(rows, sort))
     |> assign(:quadrant, Analytics.menu_quadrant(rows))
     |> assign(:category_mix, Analytics.category_mix(scope, from_date, to_date))}
  end

  defp range_dates(venue, "today") do
    today = Tenants.business_date(venue)
    {today, today}
  end

  defp range_dates(venue, "30d") do
    today = Tenants.business_date(venue)
    {Date.add(today, -29), today}
  end

  defp range_dates(venue, _seven_day) do
    today = Tenants.business_date(venue)
    {Date.add(today, -6), today}
  end

  defp sort_rows(rows, "rating") do
    Enum.sort_by(
      rows,
      fn row -> (row.rating && row.rating.avg) || Decimal.new(-1) end,
      {:desc, Decimal}
    )
  end

  defp sort_rows(rows, "margin_pct") do
    Enum.sort_by(rows, fn row -> row.margin_pct || Decimal.new(-1) end, {:desc, Decimal})
  end

  defp sort_rows(rows, field) when field in ["food_cost", "margin"] do
    Enum.sort_by(rows, &Map.fetch!(&1, String.to_existing_atom(field)), {:desc, Money})
  end

  defp sort_rows(rows, field) when field in ["sold", "sellout_days"] do
    Enum.sort_by(rows, &Map.fetch!(&1, String.to_existing_atom(field)), :desc)
  end

  defp sort_rows(rows, _revenue), do: Enum.sort_by(rows, & &1.revenue, {:desc, Money})
end

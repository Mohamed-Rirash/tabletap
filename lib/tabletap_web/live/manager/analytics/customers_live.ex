defmodule TabletapWeb.Manager.Analytics.CustomersLive do
  @moduledoc """
  Owner-dashboard.md Screen 7 — Customers (build-plan.md Feature 18),
  "MVP-honest: we only know what our data supports." New vs returning,
  a visit-frequency histogram, the 30-day repeat rate, and top spenders
  (account holders only — privacy-safe, no guest_token rows) all read
  from `Tabletap.Analytics.customers_summary/3` and `top_customers/4`.
  Loyalty/segments/marketing are explicitly post-MVP (owner-dashboard.md
  itself defers them to "the loyalty engine we deferred") — not built
  here.
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
      active_nav={:analytics_customers}
      venues={@venues}
    >
      <div class="flex items-center justify-between flex-wrap gap-4 mb-6">
        <h1 class="text-2xl font-bold">{gettext("Customers")}</h1>
        <.range_picker range={@range} />
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <p class="text-xs font-medium text-base-content/60">{gettext("New customers")}</p>
          <p class="mt-1 text-2xl font-bold tabular-nums">{@summary.new_count}</p>
        </div>
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <p class="text-xs font-medium text-base-content/60">{gettext("Returning customers")}</p>
          <p class="mt-1 text-2xl font-bold tabular-nums">{@summary.returning_count}</p>
        </div>
        <div class="rounded-box border border-base-300 bg-base-100 p-4 sm:col-span-2">
          <p class="text-xs font-medium text-base-content/60">
            {gettext("Repeat rate (30-day, accounts)")}
          </p>
          <p class="mt-1 text-2xl font-bold tabular-nums">
            {if @summary.repeat_rate, do: "#{Float.round(@summary.repeat_rate * 100, 0)}%", else: "—"}
          </p>
          <p class="text-xs text-base-content/50 mt-0.5">
            {gettext("% of account holders with 2+ orders in the trailing 30 days")}
          </p>
        </div>
      </div>

      <div class="grid gap-6 lg:grid-cols-2">
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="font-semibold mb-3">{gettext("Visit frequency")}</h2>
          <.frequency_bars frequency={@summary.visit_frequency} />
        </div>

        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="font-semibold mb-3">{gettext("Top customers by spend")}</h2>
          <p class="text-xs text-base-content/50 mb-2">
            {gettext("Account holders only — privacy-safe, no anonymous guests shown.")}
          </p>
          <.top_customers_list customers={@top_customers} locale={@locale} />
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
        patch={~p"/analytics/customers?#{[range: "7d"]}"}
        class={["btn btn-sm join-item", @range == "7d" && "btn-primary"]}
      >
        {gettext("7d")}
      </.link>
      <.link
        patch={~p"/analytics/customers?#{[range: "30d"]}"}
        class={["btn btn-sm join-item", @range == "30d" && "btn-primary"]}
      >
        {gettext("30d")}
      </.link>
      <.link
        patch={~p"/analytics/customers?#{[range: "90d"]}"}
        class={["btn btn-sm join-item", @range == "90d" && "btn-primary"]}
      >
        {gettext("90d")}
      </.link>
    </div>
    """
  end

  attr :frequency, :map, required: true

  defp frequency_bars(assigns) do
    max_count = assigns.frequency |> Map.values() |> Enum.max(fn -> 1 end) |> max(1)
    assigns = assign(assigns, max_count: max_count)

    ~H"""
    <div class="flex items-end gap-3 h-24">
      <div :for={bucket <- ["1", "2-3", "4+"]} class="flex-1 flex flex-col items-center gap-1">
        <div
          class="w-full bg-brand/70 rounded-t"
          style={"height: #{bar_height(Map.get(@frequency, bucket, 0), @max_count)}%"}
        >
        </div>
        <span class="text-[10px] text-base-content/50">{bucket}× ({Map.get(@frequency, bucket, 0)})</span>
      </div>
    </div>
    """
  end

  defp bar_height(0, _max), do: 0
  defp bar_height(value, max), do: max(round(value / max * 100), 2)

  attr :customers, :list, required: true
  attr :locale, :string, required: true

  defp top_customers_list(assigns) do
    ~H"""
    <p :if={@customers == []} class="text-sm text-base-content/50">
      {gettext("No account-holder orders yet.")}
    </p>
    <ol :if={@customers != []} class="text-sm space-y-1.5 list-decimal list-inside">
      <li :for={customer <- @customers} class="flex items-center justify-between gap-2">
        <span class="truncate">{customer.email}
        <span class="text-base-content/40">({customer.order_count})</span></span>
        <span class="tabular-nums shrink-0"><.money amount={customer.total} locale={@locale} /></span>
      </li>
    </ol>
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

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:summary, Analytics.customers_summary(scope, from_date, to_date))
     |> assign(:top_customers, Analytics.top_customers(scope, from_date, to_date))}
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

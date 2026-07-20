defmodule TabletapWeb.Manager.FeedbackLive do
  @moduledoc """
  The manager feedback screen — Feature 17's simple newest-first list,
  now owner-dashboard.md's full "Screen 4 — Feedback" (build-plan.md
  Feature 18): a rating trend, the 1-5 distribution, rating rate,
  per-item worst/best-first list, per-waiter averages (always shown
  alongside the venue's own average and hours on shift — design-qa.md's
  fairness guardrail, never a naked leaderboard), and the low-rating
  alert (< 3.0 over an item's last 20 ratings, all-time — a current
  state, not date-range bound, so it stays visible regardless of which
  range is selected).

  Every number reuses `Tabletap.Analytics`'s own range-bound reads
  (`feedback_trend/3`, `rating_distribution/3`, `rating_rate/3`,
  `per_waiter_ratings/3`, `worst_rated_items/1`, `low_rated_items/1`)
  — none of it duplicates a query already living there. The recent-
  comments list underneath is Feature 17's own `list_venue_feedback/1`,
  unchanged, still live via `"venue:<id>:ratings"`.
  """
  use TabletapWeb, :live_view

  alias Tabletap.{Analytics, Feedback, Tenants}

  @ranges ~w(today 7d 30d)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:feedback}
      venues={@venues}
    >
      <div class="flex items-center justify-between flex-wrap gap-4 mb-2">
        <h1 class="text-2xl font-bold">{gettext("Feedback")}</h1>
        <.range_picker range={@range} />
      </div>
      <p class="text-sm text-base-content/60 mb-6 max-w-prose">
        {gettext("Every rating your customers have left, newest first.")}
      </p>

      <div
        :if={@low_rated != []}
        class="rounded-box bg-error/10 border border-error/30 p-4 mb-6"
      >
        <p class="font-medium text-error flex items-center gap-2">
          <.icon name="hero-exclamation-triangle" class="size-4" />
          {gettext("Low-rating alert")}
        </p>
        <ul class="text-sm mt-1 space-y-0.5">
          <li :for={item <- @low_rated}>
            {item.name} — {gettext("%{avg} avg over its last 20 ratings",
              avg: Float.round(item.avg, 1)
            )}
          </li>
        </ul>
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-3 gap-3 mb-6">
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <p class="text-xs font-medium text-base-content/60">{gettext("Rating rate")}</p>
          <p class="mt-1 text-2xl font-bold tabular-nums">
            {if @rating_rate, do: "#{Float.round(@rating_rate * 100, 0)}%", else: "—"}
          </p>
          <p class="text-xs text-base-content/50 mt-0.5">
            {gettext("of served orders got rated — low means the prompt isn't landing")}
          </p>
        </div>
        <div class="rounded-box border border-base-300 bg-base-100 p-4 sm:col-span-2">
          <p class="text-xs font-medium text-base-content/60 mb-2">
            {gettext("Rating distribution")}
          </p>
          <.distribution_bars distribution={@distribution} />
        </div>
      </div>

      <div class="rounded-box border border-base-300 bg-base-100 p-4 mb-6">
        <h2 class="font-semibold mb-1">{gettext("Venue rating trend")}</h2>
        <p class="text-xs text-base-content/50 mb-3">
          {gettext("So what: %{caption}", caption: trend_caption(@trend))}
        </p>
        <.trend_bars trend={@trend} />
      </div>

      <div class="grid gap-6 lg:grid-cols-2 mb-6">
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <div class="flex items-center justify-between mb-3">
            <h2 class="font-semibold">{gettext("Per-item ratings")}</h2>
            <button type="button" phx-click="toggle_item_sort" class="btn btn-xs btn-outline">
              {if @worst_first, do: gettext("Worst first"), else: gettext("Best first")}
            </button>
          </div>
          <.per_item_list items={@sorted_items} />
        </div>

        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="font-semibold mb-1">{gettext("Per-waiter ratings")}</h2>
          <p class="text-xs text-base-content/50 mb-3">
            {gettext("Always shown with hours worked — a quiet Tuesday isn't a slow waiter.")}
          </p>
          <.per_waiter_list waiters={@per_waiter} venue_avg={@venue_avg_for_period} />
        </div>
      </div>

      <div :if={@ratings == []} class="rounded-box bg-base-100 border border-base-300 p-6 text-center">
        <.icon name="hero-chat-bubble-left-right" class="size-8 mx-auto opacity-40" />
        <p class="mt-2 font-medium">{gettext("No ratings yet.")}</p>
        <p class="text-sm text-base-content/60">
          {gettext("They'll show up here the moment a customer rates a served order.")}
        </p>
      </div>

      <div
        :if={@ratings != []}
        class="rounded-box bg-base-100 border border-base-300 divide-y divide-base-300"
      >
        <div :for={rating <- @ratings} id={"rating-#{rating.id}"} class="p-4">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="font-medium">{rating.order_item.menu_item.name}</p>
              <p class="text-xs text-base-content/50">
                {gettext("Order #%{number} — %{date}",
                  number: rating.order_item.order.number,
                  date: Calendar.strftime(rating.inserted_at, "%b %-d, %Y %H:%M")
                )}
              </p>
            </div>
            <div class="flex items-center gap-0.5 shrink-0">
              <.icon
                :for={n <- 1..5}
                name={if n <= rating.stars, do: "hero-star-solid", else: "hero-star"}
                class={["size-4", n <= rating.stars && "text-warning"]}
              />
            </div>
          </div>
          <p :if={rating.comment} class="text-sm text-base-content/70 mt-2 italic">
            "{rating.comment}"
          </p>
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
        patch={~p"/feedback?#{[range: "today"]}"}
        class={["btn btn-sm join-item", @range == "today" && "btn-primary"]}
      >
        {gettext("Today")}
      </.link>
      <.link
        patch={~p"/feedback?#{[range: "7d"]}"}
        class={["btn btn-sm join-item", @range == "7d" && "btn-primary"]}
      >
        {gettext("7d")}
      </.link>
      <.link
        patch={~p"/feedback?#{[range: "30d"]}"}
        class={["btn btn-sm join-item", @range == "30d" && "btn-primary"]}
      >
        {gettext("30d")}
      </.link>
    </div>
    """
  end

  attr :distribution, :map, required: true

  defp distribution_bars(assigns) do
    max_count = assigns.distribution |> Map.values() |> Enum.max(fn -> 1 end) |> max(1)
    assigns = assign(assigns, max_count: max_count)

    ~H"""
    <div class="flex items-end gap-2 h-16">
      <div :for={star <- 1..5} class="flex-1 flex flex-col items-center gap-1">
        <div
          class="w-full bg-warning/70 rounded-t"
          style={"height: #{bar_height(Map.get(@distribution, star, 0), @max_count)}%"}
        >
        </div>
        <span class="text-[10px] text-base-content/50">{star}★ ({Map.get(@distribution, star, 0)})</span>
      </div>
    </div>
    """
  end

  attr :trend, :list, required: true

  defp trend_bars(assigns) do
    max_avg = assigns.trend |> Enum.map(& &1.avg) |> Enum.max(fn -> 5 end) |> max(1)
    assigns = assign(assigns, max_avg: max_avg)

    ~H"""
    <p :if={@trend == []} class="text-sm text-base-content/50">
      {gettext("No ratings in this period.")}
    </p>
    <div :if={@trend != []} class="flex items-end gap-1 h-24">
      <div :for={day <- @trend} class="flex-1 flex flex-col items-center gap-1">
        <div
          class="w-full bg-brand/70 rounded-t"
          style={"height: #{bar_height(day.avg, @max_avg)}%"}
          title={"#{day.date}: #{Float.round(day.avg, 1)} (#{day.count})"}
        >
        </div>
        <span class="text-[10px] text-base-content/40">{Calendar.strftime(day.date, "%-m/%-d")}</span>
      </div>
    </div>
    """
  end

  defp bar_height(0, _max), do: 0
  defp bar_height(value, max), do: max(round(value / max * 100), 2)

  attr :items, :list, required: true

  defp per_item_list(assigns) do
    ~H"""
    <p :if={@items == []} class="text-sm text-base-content/50">{gettext("No rated items yet.")}</p>
    <ul :if={@items != []} class="text-sm space-y-1.5">
      <li :for={item <- @items} class="flex items-center justify-between">
        <span class="truncate">{item.name}</span>
        <span class="tabular-nums shrink-0 ml-2">
          {Decimal.round(item.avg, 1)}★ <span class="text-base-content/40">({item.count})</span>
        </span>
      </li>
    </ul>
    """
  end

  attr :waiters, :list, required: true
  attr :venue_avg, :any, required: true

  defp per_waiter_list(assigns) do
    ~H"""
    <p :if={@waiters == []} class="text-sm text-base-content/50">
      {gettext("No waiter-served ratings in this period.")}
    </p>
    <ul :if={@waiters != []} class="text-sm space-y-1.5">
      <li :for={row <- @waiters} class="flex items-center justify-between">
        <span class="truncate">{row.email}</span>
        <span class="tabular-nums shrink-0 ml-2">
          {Float.round(row.avg, 1)}★
          <span class="text-base-content/40">({row.count}, {row.hours}h)</span>
        </span>
      </li>
    </ul>
    <p :if={@venue_avg} class="text-xs text-base-content/50 mt-2 pt-2 border-t border-base-300">
      {gettext("Venue average this period: %{avg}★", avg: Float.round(@venue_avg, 1))}
    </p>
    """
  end

  defp trend_caption([]), do: gettext("no ratings yet")

  defp trend_caption(trend) do
    avg = trend |> Enum.map(& &1.avg) |> Enum.sum() |> Kernel./(length(trend))
    gettext("averaging %{avg}★ across this period", avg: Float.round(avg, 1))
  end

  ## Mount / params

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{scope.venue.id}:ratings")
    end

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:venues, Tenants.list_venues(scope))
     |> assign(:worst_first, true)
     |> assign(:ratings, Feedback.list_venue_feedback(scope))
     |> assign(:low_rated, Analytics.low_rated_items(scope))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    range = if params["range"] in @ranges, do: params["range"], else: "7d"
    {:noreply, socket |> assign(:range, range) |> load_range()}
  end

  @impl true
  def handle_event("toggle_item_sort", _params, socket) do
    worst_first = !socket.assigns.worst_first

    {:noreply,
     socket
     |> assign(:worst_first, worst_first)
     |> assign(:sorted_items, sort_items(socket.assigns.items, worst_first))}
  end

  @impl true
  def handle_info({:rating_submitted, _menu_item_id}, socket) do
    {:noreply,
     socket
     |> assign(:ratings, Feedback.list_venue_feedback(socket.assigns.current_scope))
     |> assign(:low_rated, Analytics.low_rated_items(socket.assigns.current_scope))
     |> load_range()}
  end

  defp load_range(socket) do
    scope = socket.assigns.current_scope
    {from_date, to_date} = range_dates(scope.venue, socket.assigns.range)

    items = Analytics.worst_rated_items(scope)
    days = Analytics.range_summary(scope, from_date, to_date)
    per_waiter = per_waiter_with_names(scope, from_date, to_date, days)

    socket
    |> assign(:trend, Analytics.feedback_trend(scope, from_date, to_date))
    |> assign(:distribution, Analytics.rating_distribution(scope, from_date, to_date))
    |> assign(:rating_rate, Analytics.rating_rate(scope, from_date, to_date))
    |> assign(:items, items)
    |> assign(:sorted_items, sort_items(items, socket.assigns[:worst_first] != false))
    |> assign(:per_waiter, per_waiter)
    |> assign(:venue_avg_for_period, venue_avg(per_waiter))
  end

  defp sort_items(items, true), do: Enum.sort_by(items, & &1.avg, Decimal)
  defp sort_items(items, false), do: Enum.sort_by(items, & &1.avg, {:desc, Decimal})

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

  defp per_waiter_with_names(scope, from_date, to_date, days) do
    rows = Analytics.per_waiter_ratings(scope, from_date, to_date)
    membership_ids = Enum.map(rows, & &1.waiter_membership_id)
    memberships = Tenants.list_memberships(scope, membership_ids) |> Map.new(&{&1.id, &1})
    hours_by_waiter = Analytics.waiter_hours_by_membership(days)

    Enum.map(rows, fn row ->
      membership = memberships[row.waiter_membership_id]

      %{
        email: membership && membership.user.email,
        avg: row.avg,
        count: row.count,
        hours: Map.get(hours_by_waiter, row.waiter_membership_id, 0.0) |> Float.round(1)
      }
    end)
  end

  defp venue_avg([]), do: nil

  defp venue_avg(rows),
    do: rows |> Enum.map(& &1.avg) |> Enum.sum() |> Kernel./(length(rows)) |> Float.round(1)
end

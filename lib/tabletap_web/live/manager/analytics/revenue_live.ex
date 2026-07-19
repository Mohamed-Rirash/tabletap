defmodule TabletapWeb.Manager.Analytics.RevenueLive do
  @moduledoc """
  Owner-dashboard.md Screen 2 — Revenue & Sales (build-plan.md Feature
  18). Date-range picker (today / 7d / 30d / custom), every headline
  number compared to the immediately-preceding period of the same
  length (`Analytics.previous_period_range/2`). Reads
  `Analytics.range_summary/3` — closed days from `daily_rollups`,
  today's own number live — the same function the Today screen's
  tiles read, so the two screens can never disagree on an overlapping
  day.

  Trend rows render as a plain per-day bar list rather than a true
  ghosted-previous-period line chart — no charting dependency exists in
  this app, and a second overlaid series is a lot of SVG for a first
  cut. The previous-period comparison itself still happens, just as a
  single %-change figure on each headline stat rather than a second
  bar per day; documented here rather than silently downgraded.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Analytics
  alias Tabletap.Tenants

  @ranges ~w(today 7d 30d)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:analytics_revenue}
      venues={@venues}
    >
      <div class="flex items-center justify-between flex-wrap gap-4 mb-6">
        <h1 class="text-2xl font-bold">{gettext("Revenue & Sales")}</h1>
        <div class="flex items-center gap-2">
          <.range_picker range={@range} from_date={@from_date} to_date={@to_date} />
          <a
            href={
              ~p"/analytics/revenue.csv?#{[from: Date.to_string(@from_date), to: Date.to_string(@to_date)]}"
            }
            class="btn btn-sm btn-outline"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export CSV")}
          </a>
        </div>
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-6">
        <.stat_tile
          label={gettext("Net revenue")}
          value={format_money(@totals.net_revenue, @locale)}
          change={@change.net_revenue}
        />
        <.stat_tile
          label={gettext("Orders")}
          value={@totals.order_count}
          change={@change.order_count}
        />
        <.stat_tile
          label={gettext("Average check")}
          value={if @totals.avg_check, do: format_money(@totals.avg_check, @locale), else: "—"}
          change={@change.avg_check}
        />
        <.stat_tile
          label={gettext("Gross profit")}
          value={format_money(@totals.gross_profit, @locale)}
          change={@change.gross_profit}
        />
      </div>

      <.trend_chart
        title={gettext("Revenue trend")}
        caption={
          gettext("So what: %{caption}", caption: trend_caption(@days, & &1.net_revenue, @locale))
        }
        days={@days}
        value_fn={& &1.net_revenue}
        locale={@locale}
      />

      <.trend_chart
        title={gettext("Orders trend")}
        caption={gettext("So what: %{caption}", caption: count_trend_caption(@days))}
        days={@days}
        value_fn={& &1.order_count}
        locale={nil}
      />

      <div class="grid gap-6 lg:grid-cols-2 mt-6">
        <.breakdown_card title={gettext("Channel mix")}>
          <.mix_rows rows={@channel_rows} locale={@locale} />
        </.breakdown_card>

        <.breakdown_card title={gettext("Payment mix")}>
          <.mix_rows rows={@payment_rows} locale={@locale} />
        </.breakdown_card>
      </div>

      <div class="grid gap-6 lg:grid-cols-3 mt-6">
        <.money_stat_card
          title={gettext("Discounts given")}
          total={@discounts.total}
          count={@discounts.count}
          locale={@locale}
          by={Enum.map(@discounts.by_staff, &{&1.email, &1.total, &1.count})}
        />
        <.money_stat_card
          title={gettext("Comps given")}
          total={@comps.total}
          count={@comps.count}
          locale={@locale}
          by={Enum.map(@comps.by_reason, &{&1.reason, &1.total, &1.count})}
        />
        <.refunds_card refunds={@refunds} locale={@locale} />
      </div>

      <div class="grid gap-6 lg:grid-cols-2 mt-6">
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="font-semibold mb-1">{gettext("Platform fees paid")}</h2>
          <p class="text-2xl font-bold tabular-nums">
            <.money amount={@platform_fees} locale={@locale} />
          </p>
          <p class="text-xs text-base-content/50 mt-1">
            {gettext("So what: full cost of accepting wallet payments this period.")}
          </p>
        </div>

        <.breakdown_card title={gettext("Peak hours")}>
          <p class="text-xs text-base-content/50 mb-2">
            {gettext("So what: staff and prep for the busiest hours below.")}
          </p>
          <.hourly_bars hourly={@hourly} />
        </.breakdown_card>
      </div>
    </Layouts.manager>
    """
  end

  ## Function components

  attr :range, :string, required: true
  attr :from_date, Date, required: true
  attr :to_date, Date, required: true

  defp range_picker(assigns) do
    ~H"""
    <div class="join">
      <.link
        patch={~p"/analytics/revenue?#{[range: "today"]}"}
        class={["btn btn-sm join-item", @range == "today" && "btn-primary"]}
      >
        {gettext("Today")}
      </.link>
      <.link
        patch={~p"/analytics/revenue?#{[range: "7d"]}"}
        class={["btn btn-sm join-item", @range == "7d" && "btn-primary"]}
      >
        {gettext("7d")}
      </.link>
      <.link
        patch={~p"/analytics/revenue?#{[range: "30d"]}"}
        class={["btn btn-sm join-item", @range == "30d" && "btn-primary"]}
      >
        {gettext("30d")}
      </.link>
    </div>
    <form phx-submit="set_custom_range" class="flex items-center gap-1">
      <input type="date" name="from" value={@from_date} class="input input-sm" />
      <span class="text-sm text-base-content/50">{gettext("to")}</span>
      <input type="date" name="to" value={@to_date} class="input input-sm" />
      <button type="submit" class="btn btn-sm btn-outline">{gettext("Go")}</button>
    </form>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :change, :any, required: true

  defp stat_tile(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-4">
      <p class="text-xs font-medium text-base-content/60">{@label}</p>
      <p class="mt-1 text-2xl font-bold tabular-nums">{@value}</p>
      <p :if={@change} class={["mt-0.5 text-xs", change_class(@change)]}>
        {change_label(@change)}
      </p>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :caption, :string, required: true
  attr :days, :list, required: true
  attr :value_fn, :any, required: true
  attr :locale, :any, default: nil

  defp trend_chart(assigns) do
    values = Enum.map(assigns.days, &to_number(assigns.value_fn.(&1)))
    max_value = Enum.max([1 | values])
    assigns = assign(assigns, values: values, max_value: max_value)

    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-4 mt-6">
      <h2 class="font-semibold">{@title}</h2>
      <p class="text-xs text-base-content/50 mb-3">{@caption}</p>
      <div class="flex items-end gap-1 h-32">
        <div
          :for={{day, value} <- Enum.zip(@days, @values)}
          class="flex-1 flex flex-col items-center gap-1"
        >
          <div
            class="w-full bg-brand/70 rounded-t"
            style={"height: #{bar_height(value, @max_value)}%"}
            title={bar_title(day, value, @locale)}
          >
          </div>
          <span class="text-[10px] text-base-content/40">{Calendar.strftime(day.date, "%-m/%-d")}</span>
        </div>
      </div>
    </div>
    """
  end

  defp to_number(%Money{} = money), do: money |> Money.to_decimal() |> Decimal.to_float()
  defp to_number(number) when is_number(number), do: number

  defp bar_height(_value, max) when max <= 0, do: 2
  defp bar_height(0, _max), do: 0
  defp bar_height(value, max), do: max(round(value / max * 100), 2)

  defp bar_title(day, value, nil), do: "#{day.date}: #{value}"
  defp bar_title(day, _value, _locale), do: "#{day.date}"

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp breakdown_card(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-4">
      <h2 class="font-semibold mb-3">{@title}</h2>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :locale, :string, required: true

  defp mix_rows(assigns) do
    ~H"""
    <p :if={@rows == []} class="text-sm text-base-content/50">{gettext("No data yet.")}</p>
    <dl :if={@rows != []} class="space-y-2 text-sm">
      <div :for={{label, count, amount} <- @rows} class="flex items-center justify-between">
        <dt class="text-base-content/70">
          {label} <span class="text-base-content/40">({count})</span>
        </dt>
        <dd class="font-semibold"><.money amount={amount} locale={@locale} /></dd>
      </div>
    </dl>
    """
  end

  attr :title, :string, required: true
  attr :total, Money, required: true
  attr :count, :integer, required: true
  attr :locale, :string, required: true
  attr :by, :list, required: true

  defp money_stat_card(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-4">
      <h2 class="font-semibold">{@title}</h2>
      <p class="mt-1 text-2xl font-bold tabular-nums">
        <.money amount={@total} locale={@locale} />
        <span class="text-sm text-base-content/40">({@count})</span>
      </p>
      <div :if={@by != []} class="mt-3 pt-3 border-t border-base-300 space-y-1 text-sm">
        <div
          :for={{label, amount, count} <- Enum.take(@by, 5)}
          class="flex items-center justify-between"
        >
          <span class="text-base-content/70 truncate">{label}</span>
          <span class="tabular-nums shrink-0 ml-2">
            <.money amount={amount} locale={@locale} /> ({count})
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :refunds, :map, required: true
  attr :locale, :string, required: true

  defp refunds_card(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-4">
      <h2 class="font-semibold">{gettext("Refunds")}</h2>
      <p class="mt-1 text-2xl font-bold tabular-nums">
        <.money amount={@refunds.total} locale={@locale} />
        <span class="text-sm text-base-content/40">({@refunds.count})</span>
      </p>
      <p class="text-xs text-base-content/50 mt-1">
        {if @refunds.rate,
          do:
            gettext("%{pct}% of orders — a rising rate is an ops fire alarm.",
              pct: pct(@refunds.rate)
            ),
          else: gettext("No orders in this period.")}
      </p>
      <div :if={@refunds.by_reason != []} class="mt-3 pt-3 border-t border-base-300 space-y-1 text-sm">
        <div :for={row <- Enum.take(@refunds.by_reason, 5)} class="flex items-center justify-between">
          <span class="text-base-content/70 truncate">{row.reason}</span>
          <span class="tabular-nums shrink-0 ml-2"><.money amount={row.total} locale={@locale} />
          ({row.count})</span>
        </div>
      </div>
    </div>
    """
  end

  attr :hourly, :map, required: true

  defp hourly_bars(assigns) do
    max_count = assigns.hourly |> Map.values() |> Enum.max(fn -> 1 end) |> max(1)
    assigns = assign(assigns, max_count: max_count)

    ~H"""
    <div class="flex items-end gap-0.5 h-20">
      <div :for={hour <- 0..23} class="flex-1 flex flex-col items-center justify-end h-full">
        <div
          class="w-full bg-brand/60 rounded-t"
          style={"height: #{bar_height(Map.get(@hourly, to_string(hour), 0), @max_count)}%"}
          title={"#{hour}:00 — #{Map.get(@hourly, to_string(hour), 0)}"}
        >
        </div>
      </div>
    </div>
    <div class="flex justify-between text-[10px] text-base-content/40 mt-1">
      <span>0:00</span>
      <span>12:00</span>
      <span>23:00</span>
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
    {range, from_date, to_date} = resolve_range(scope.venue, params)

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:from_date, from_date)
     |> assign(:to_date, to_date)
     |> load_data(from_date, to_date)}
  end

  @impl true
  def handle_event("set_custom_range", %{"from" => from, "to" => to}, socket) do
    {:noreply, push_patch(socket, to: ~p"/analytics/revenue?#{[from: from, to: to]}")}
  end

  defp resolve_range(_venue, %{"from" => from, "to" => to}) when from != "" and to != "" do
    {"custom", Date.from_iso8601!(from), Date.from_iso8601!(to)}
  end

  defp resolve_range(venue, %{"range" => range}) when range in @ranges do
    {from_date, to_date} = resolve_range_dates(venue, range)
    {range, from_date, to_date}
  end

  defp resolve_range(venue, _params) do
    {from_date, to_date} = resolve_range_dates(venue, "7d")
    {"7d", from_date, to_date}
  end

  defp resolve_range_dates(venue, "today") do
    today = Tenants.business_date(venue)
    {today, today}
  end

  defp resolve_range_dates(venue, "7d") do
    today = Tenants.business_date(venue)
    {Date.add(today, -6), today}
  end

  defp resolve_range_dates(venue, "30d") do
    today = Tenants.business_date(venue)
    {Date.add(today, -29), today}
  end

  defp load_data(socket, from_date, to_date) do
    scope = socket.assigns.current_scope
    days = Analytics.range_summary(scope, from_date, to_date)
    {prev_from, prev_to} = Analytics.previous_period_range(from_date, to_date)
    prev_days = Analytics.range_summary(scope, prev_from, prev_to)

    totals = totals_for(days, scope.venue)
    prev_totals = totals_for(prev_days, scope.venue)

    socket
    |> assign(:days, days)
    |> assign(:totals, totals)
    |> assign(:change, change_for(totals, prev_totals))
    |> assign(:channel_rows, channel_rows(days, scope.venue))
    |> assign(:payment_rows, payment_rows(days, scope.venue))
    |> assign(:discounts, Analytics.discounts_breakdown(scope, from_date, to_date))
    |> assign(:comps, Analytics.comps_breakdown(scope, from_date, to_date))
    |> assign(:refunds, Analytics.refunds_breakdown(scope, from_date, to_date))
    |> assign(:platform_fees, Analytics.platform_fees_paid(scope, from_date, to_date))
    |> assign(:hourly, Analytics.hourly_totals(scope, from_date, to_date))
  end

  defp totals_for(days, venue) do
    zero = Money.new!(venue.currency, 0)
    net_revenue = days |> Enum.map(& &1.net_revenue) |> Enum.reduce(zero, &Money.add!(&2, &1))
    food_cost = days |> Enum.map(& &1.food_cost) |> Enum.reduce(zero, &Money.add!(&2, &1))
    order_count = days |> Enum.map(& &1.order_count) |> Enum.sum()

    %{
      net_revenue: net_revenue,
      order_count: order_count,
      avg_check: if(order_count > 0, do: Money.div!(net_revenue, order_count), else: nil),
      gross_profit: Money.sub!(net_revenue, food_cost)
    }
  end

  defp change_for(totals, prev_totals) do
    %{
      net_revenue: pct_change(totals.net_revenue, prev_totals.net_revenue),
      order_count: pct_change(totals.order_count, prev_totals.order_count),
      avg_check: pct_change(totals.avg_check, prev_totals.avg_check),
      gross_profit: pct_change(totals.gross_profit, prev_totals.gross_profit)
    }
  end

  defp pct_change(nil, _prev), do: nil
  defp pct_change(_current, nil), do: nil

  defp pct_change(%Money{} = current, %Money{} = prev) do
    pct_change(
      Money.to_decimal(current) |> Decimal.to_float(),
      Money.to_decimal(prev) |> Decimal.to_float()
    )
  end

  defp pct_change(_current, prev) when prev == 0, do: nil

  defp pct_change(current, prev) when is_number(current) and is_number(prev) do
    (current - prev) / prev * 100
  end

  defp change_class(pct) when pct > 0, do: "text-success"
  defp change_class(pct) when pct < 0, do: "text-error"
  defp change_class(_pct), do: "text-base-content/50"

  defp change_label(pct) do
    sign = if pct >= 0, do: "+", else: ""
    gettext("%{sign}%{pct}% vs previous period", sign: sign, pct: Float.round(pct, 1))
  end

  defp channel_rows(days, venue) do
    zero = Money.new!(venue.currency, 0)

    days
    |> Enum.flat_map(& &1.channel_mix)
    |> Enum.group_by(fn {kind, _row} -> kind end, fn {_kind, row} -> row end)
    |> Enum.map(fn {kind, rows} ->
      count = rows |> Enum.map(& &1["count"]) |> Enum.sum()

      amount =
        rows
        |> Enum.map(&money_from_jsonb(&1["revenue"]))
        |> Enum.reduce(zero, &Money.add!(&2, &1))

      {kind_label(kind), count, amount}
    end)
    |> Enum.sort_by(fn {_label, _count, amount} -> amount end, {:desc, Money})
  end

  defp payment_rows(days, venue) do
    zero = Money.new!(venue.currency, 0)

    days
    |> Enum.flat_map(& &1.payment_mix)
    |> Enum.group_by(fn {provider, _row} -> provider end, fn {_provider, row} -> row end)
    |> Enum.map(fn {provider, rows} ->
      count = rows |> Enum.map(& &1["count"]) |> Enum.sum()

      amount =
        rows
        |> Enum.map(&money_from_jsonb(&1["amount"]))
        |> Enum.reduce(zero, &Money.add!(&2, &1))

      {String.capitalize(provider), count, amount}
    end)
    |> Enum.sort_by(fn {_label, _count, amount} -> amount end, {:desc, Money})
  end

  defp money_from_jsonb(%{"amount" => amount, "currency" => currency}) do
    Money.new!(String.to_existing_atom(currency), amount)
  end

  defp kind_label("dine_in"), do: gettext("Dine in")
  defp kind_label("takeaway"), do: gettext("Takeaway")
  defp kind_label("counter"), do: gettext("Counter")
  defp kind_label(other), do: other

  defp pct(rate), do: rate |> Kernel.*(100) |> Float.round(1)

  defp trend_caption(days, value_fn, locale) do
    values = Enum.map(days, &to_number(value_fn.(&1)))
    high = Enum.max(values, fn -> 0 end)
    high_day = Enum.find(days, &(to_number(value_fn.(&1)) == high))

    if high_day do
      gettext("busiest day was %{date} at %{amount}",
        date: Calendar.strftime(high_day.date, "%b %-d"),
        amount: format_money(high_day.net_revenue, locale)
      )
    else
      gettext("no data yet")
    end
  end

  defp count_trend_caption(days) do
    total = days |> Enum.map(& &1.order_count) |> Enum.sum()
    gettext("%{count} orders across this period", count: total)
  end
end

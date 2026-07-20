defmodule TabletapWeb.Manager.Analytics.ReportsLive do
  @moduledoc """
  The Report Center (build-plan.md Feature 18; owner-dashboard.md
  "Report Center — every report, every period"). One screen, 13 report
  types, a daily/weekly/monthly/yearly/custom period picker, on-screen
  view + CSV export. Available to manager and owner alike
  (owner-dashboard.md's own visibility rule: "the manager sees every
  report for their venue"); the Profit report's org-wide rollup
  (`Tabletap.Analytics.Reports.org_profit_rollup/3`) is the one
  owner-only extra, gated inline rather than behind a second route.

  Every report reads `Tabletap.Analytics.Reports.generate/4`, which
  itself reuses `Tabletap.Analytics`'s Screen 1-7 functions wherever
  the shape already exists — this page and its own CSV export
  (`Manager.Analytics.ReportsCsvController`) call the identical
  function, so a report can never show a different number on screen
  than in its own download.

  "Email this report" opts the current membership into
  `Workers.SendScheduledReports`' recurring delivery of whichever
  report/frequency is picked — scoped to the signed-in membership, so
  each manager manages only their own subscriptions.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Analytics.Reports
  alias Tabletap.Tenants

  @periods ~w(today 7d 30d this_month this_year custom)

  @report_labels %{
    revenue: "Revenue",
    orders: "Orders",
    successful_orders: "Successful orders & bills",
    payments: "Payments (money-in)",
    cashier_daily_cash: "Cashier daily cash",
    assisted_orders: "Assisted orders",
    inventory: "Inventory",
    menu_performance: "Menu performance",
    feedback: "Feedback",
    employee_work: "Employee work",
    customers: "Customers",
    day_close: "Day-close (Z) reports",
    profit: "Profit (P&L-lite)"
  }

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:analytics_reports}
      venues={@venues}
    >
      <div class="flex items-center justify-between flex-wrap gap-4 mb-6">
        <h1 class="text-2xl font-bold">{gettext("Report Center")}</h1>
        <div class="flex items-center gap-2 flex-wrap">
          <form id="subscribe-form" phx-submit="subscribe" class="join">
            <select name="frequency" class="select select-sm join-item">
              <option :for={f <- @subscription_frequencies} value={f}>
                {Phoenix.Naming.humanize(f)}
              </option>
            </select>
            <button type="submit" class="btn btn-sm btn-outline join-item">
              <.icon name="hero-envelope" class="size-4" /> {gettext("Email this report")}
            </button>
          </form>
          <a
            href={
              ~p"/reports.csv?#{[report: @report_type, from: Date.to_string(@from_date), to: Date.to_string(@to_date)]}"
            }
            class="btn btn-sm btn-outline"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Export CSV")}
          </a>
        </div>
      </div>

      <ul :if={@subscriptions != []} class="text-xs text-base-content/60 flex flex-wrap gap-2 mb-4">
        <li :for={sub <- @subscriptions} class="badge badge-ghost gap-1">
          {@report_labels[sub.report_type]} · {Phoenix.Naming.humanize(sub.frequency)}
          <button
            phx-click="unsubscribe"
            phx-value-id={sub.id}
            class="text-error"
            aria-label={gettext("Unsubscribe")}
          >
            &times;
          </button>
        </li>
      </ul>

      <div class="flex flex-wrap gap-2 mb-4">
        <form id="report-picker" phx-change="pick_report">
          <select name="report" class="select select-sm">
            <option
              :for={{type, label} <- @report_labels}
              value={type}
              selected={type == @report_type}
            >
              {label}
            </option>
          </select>
        </form>
        <.period_picker period={@period} from_date={@from_date} to_date={@to_date} />
      </div>

      <p class="text-xs text-base-content/50 mb-4">
        {Date.to_string(@from_date)} – {Date.to_string(@to_date)}
      </p>

      <div class="rounded-box border border-base-300 bg-base-100 p-4 overflow-x-auto">
        <.report_body report_type={@report_type} data={@data} locale={@locale} />
      </div>
    </Layouts.manager>
    """
  end

  attr :period, :string, required: true
  attr :from_date, Date, required: true
  attr :to_date, Date, required: true

  defp period_picker(assigns) do
    ~H"""
    <div class="join">
      <.link
        :for={
          {period, label} <- [
            {"today", gettext("Today")},
            {"7d", gettext("Weekly")},
            {"30d", gettext("30d")},
            {"this_month", gettext("Monthly")},
            {"this_year", gettext("Yearly")}
          ]
        }
        patch={~p"/reports?#{[period: period]}"}
        class={["btn btn-sm join-item", @period == period && "btn-primary"]}
      >
        {label}
      </.link>
    </div>
    <form id="custom-period" phx-submit="set_custom_period" class="flex items-center gap-1">
      <input type="date" name="from" value={@from_date} class="input input-sm" />
      <span class="text-sm text-base-content/50">{gettext("to")}</span>
      <input type="date" name="to" value={@to_date} class="input input-sm" />
      <button type="submit" class="btn btn-sm btn-outline">{gettext("Go")}</button>
    </form>
    """
  end

  attr :report_type, :atom, required: true
  attr :data, :any, required: true
  attr :locale, :string, required: true

  defp report_body(%{report_type: :revenue} = assigns) do
    ~H"""
    <div class="space-y-4">
      <dl class="grid grid-cols-2 sm:grid-cols-4 gap-3 text-sm">
        <.stat label={gettext("Discounts")}>
          <.money amount={@data.discounts.total} locale={@locale} />
        </.stat>
        <.stat label={gettext("Comps")}><.money amount={@data.comps.total} locale={@locale} /></.stat>
        <.stat label={gettext("Refunds")}>
          <.money amount={@data.refunds.total} locale={@locale} />
        </.stat>
        <.stat label={gettext("Platform fees")}>
          <.money amount={@data.platform_fees} locale={@locale} />
        </.stat>
      </dl>
      <table class="table table-sm">
        <thead>
          <tr>
            <th>{gettext("Date")}</th>
            <th>{gettext("Orders")}</th>
            <th>{gettext("Gross")}</th>
            <th>{gettext("Net revenue")}</th>
            <th>{gettext("Food cost")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={day <- @data.days}>
            <td>{day.date}</td>
            <td class="tabular-nums">{day.order_count}</td>
            <td class="tabular-nums"><.money amount={day.gross_sales} locale={@locale} /></td>
            <td class="tabular-nums"><.money amount={day.net_revenue} locale={@locale} /></td>
            <td class="tabular-nums"><.money amount={day.food_cost} locale={@locale} /></td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp report_body(%{report_type: :orders} = assigns) do
    ~H"""
    <table class="table table-sm">
      <thead>
        <tr>
          <th>{gettext("#")}</th>
          <th>{gettext("Status")}</th>
          <th>{gettext("Table")}</th>
          <th>{gettext("Waiter")}</th>
          <th>{gettext("Placed")}</th>
          <th>{gettext("Total")}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={order <- @data}>
          <td>{order.number}</td>
          <td>{order.status}</td>
          <td>{order.table && order.table.number}</td>
          <td>{order.waiter_membership && order.waiter_membership.id}</td>
          <td>{order.placed_at && Calendar.strftime(order.placed_at, "%b %-d %H:%M")}</td>
          <td class="tabular-nums"><.money amount={order.total} locale={@locale} /></td>
        </tr>
        <tr :if={@data == []}>
          <td colspan="6" class="text-center text-base-content/50 py-4">
            {gettext("No orders in this period.")}
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp report_body(%{report_type: :successful_orders} = assigns) do
    ~H"""
    <table class="table table-sm">
      <thead>
        <tr>
          <th>{gettext("#")}</th>
          <th>{gettext("Items")}</th>
          <th>{gettext("Discounts")}</th>
          <th>{gettext("Total")}</th>
          <th>{gettext("Payment")}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @data}>
          <td>{row.order.number}</td>
          <td>{Enum.map_join(row.order.items, ", ", &"#{&1.qty}× #{&1.name_snapshot}")}</td>
          <td>{length(row.discounts)}</td>
          <td class="tabular-nums"><.money amount={row.order.total} locale={@locale} /></td>
          <td>{row.payment && row.payment.provider}</td>
        </tr>
        <tr :if={@data == []}>
          <td colspan="5" class="text-center text-base-content/50 py-4">
            {gettext("No served orders in this period.")}
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp report_body(%{report_type: :payments} = assigns) do
    ~H"""
    <table class="table table-sm">
      <thead>
        <tr>
          <th>{gettext("Provider")}</th>
          <th>{gettext("Order")}</th>
          <th>{gettext("Amount")}</th>
          <th>{gettext("Refunded")}</th>
          <th>{gettext("Net")}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @data}>
          <td>{row.payment.provider}</td>
          <td>{row.payment.order && row.payment.order.number}</td>
          <td class="tabular-nums"><.money amount={row.payment.amount} locale={@locale} /></td>
          <td class="tabular-nums"><.money amount={row.refunded} locale={@locale} /></td>
          <td class="tabular-nums"><.money amount={row.net} locale={@locale} /></td>
        </tr>
        <tr :if={@data == []}>
          <td colspan="5" class="text-center text-base-content/50 py-4">
            {gettext("No payments in this period.")}
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp report_body(%{report_type: :cashier_daily_cash} = assigns) do
    ~H"""
    <table class="table table-sm">
      <thead>
        <tr>
          <th>{gettext("Date")}</th>
          <th>{gettext("Orders rung")}</th>
          <th>{gettext("Cash taken")}</th>
          <th>{gettext("Expected")}</th>
          <th>{gettext("Counted")}</th>
          <th>{gettext("Variance")}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @data}>
          <td>{row.business_date}</td>
          <td class="tabular-nums">{row.cash_orders_rung}</td>
          <td class="tabular-nums"><.money amount={row.cash_taken} locale={@locale} /></td>
          <td class="tabular-nums">
            {row.expected_cash && format_money(row.expected_cash, @locale)}
          </td>
          <td class="tabular-nums">{row.counted_cash && format_money(row.counted_cash, @locale)}</td>
          <td class="tabular-nums">{row.variance && format_money(row.variance, @locale)}</td>
        </tr>
        <tr :if={@data == []}>
          <td colspan="6" class="text-center text-base-content/50 py-4">
            {gettext("No cash activity in this period.")}
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp report_body(%{report_type: :assisted_orders} = assigns) do
    ~H"""
    <table class="table table-sm">
      <thead>
        <tr>
          <th>{gettext("Staff")}</th>
          <th>{gettext("Count")}</th>
          <th>{gettext("Value")}</th>
          <th>{gettext("Dine-in")}</th>
          <th>{gettext("Takeaway")}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @data}>
          <td>{row.membership_id}</td>
          <td class="tabular-nums">{row.count}</td>
          <td class="tabular-nums"><.money amount={row.total} locale={@locale} /></td>
          <td class="tabular-nums">{row.dine_in_count}</td>
          <td class="tabular-nums">{row.takeaway_count}</td>
        </tr>
        <tr :if={@data == []}>
          <td colspan="5" class="text-center text-base-content/50 py-4">
            {gettext("No staff-assisted orders in this period.")}
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp report_body(%{report_type: :inventory} = assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-sm">
        {gettext("Food cost")}: <.money amount={@data.food_cost} locale={@locale} />
        ({if @data.food_cost_pct, do: "#{Decimal.round(@data.food_cost_pct, 1)}%", else: "—"})
      </p>
      <div class="grid gap-4 sm:grid-cols-2">
        <.simple_list
          title={gettext("Stock on hand")}
          rows={@data.stock_on_hand}
          label_fn={& &1.name}
          value_fn={&format_money(&1.value, nil)}
        />
        <.simple_list
          title={gettext("Wastage")}
          rows={@data.wastage}
          label_fn={& &1.reason}
          value_fn={&format_money(&1.cost, nil)}
        />
      </div>
    </div>
    """
  end

  defp report_body(%{report_type: :menu_performance} = assigns) do
    ~H"""
    <table class="table table-sm">
      <thead>
        <tr>
          <th>{gettext("Item")}</th>
          <th>{gettext("Sold")}</th>
          <th>{gettext("Revenue")}</th>
          <th>{gettext("Margin")}</th>
          <th>{gettext("Sold last year")}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @data.rows}>
          <td>{row.name}</td>
          <td class="tabular-nums">{row.sold}</td>
          <td class="tabular-nums"><.money amount={row.revenue} locale={@locale} /></td>
          <td class="tabular-nums"><.money amount={row.margin} locale={@locale} /></td>
          <td class="tabular-nums">{last_year_sold(@data.last_year_rows, row.menu_item_id)}</td>
        </tr>
        <tr :if={@data.rows == []}>
          <td colspan="5" class="text-center text-base-content/50 py-4">
            {gettext("No items sold in this period.")}
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp report_body(%{report_type: :feedback} = assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-sm">
        {gettext("This period avg")}: {trend_avg(@data.trend)}★ · {gettext("previous period")}: {trend_avg(
          @data.previous_trend
        )}★
      </p>
      <div class="grid gap-4 sm:grid-cols-2">
        <.simple_list
          title={gettext("Per item")}
          rows={@data.per_item}
          label_fn={& &1.name}
          value_fn={&"#{Decimal.round(&1.avg, 1)}★ (#{&1.count})"}
        />
        <div>
          <h3 class="font-semibold text-sm mb-2">{gettext("Comments")}</h3>
          <p :if={@data.ratings == []} class="text-sm text-base-content/50">
            {gettext("No comments.")}
          </p>
          <ul class="text-sm space-y-1">
            <li :for={r <- @data.ratings} :if={r.comment}>"{r.comment}" — {r.stars}★</li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  defp report_body(%{report_type: :employee_work} = assigns) do
    ~H"""
    <div class="space-y-4">
      <.simple_list
        title={gettext("Waiters")}
        rows={@data.waiters}
        label_fn={& &1.waiter_membership_id}
        value_fn={&"#{&1.orders_served} orders"}
      />
      <div>
        <h3 class="font-semibold text-sm mb-2">{gettext("Shifts")}</h3>
        <p :if={@data.shifts == []} class="text-sm text-base-content/50">
          {gettext("No shifts in this period.")}
        </p>
        <ul class="text-sm space-y-1">
          <li :for={shift <- @data.shifts}>
            {shift.membership.user.email} — {shift.started_at} {shift.auto_closed && "(auto-closed)"}
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp report_body(%{report_type: :customers} = assigns) do
    ~H"""
    <div class="space-y-4">
      <p class="text-sm">
        {gettext("New")}: {@data.summary.new_count} · {gettext("Returning")}: {@data.summary.returning_count}
      </p>
      <.simple_list
        title={gettext("Top customers")}
        rows={@data.top_customers}
        label_fn={& &1.email}
        value_fn={&format_money(&1.total, @locale)}
      />
    </div>
    """
  end

  defp report_body(%{report_type: :day_close} = assigns) do
    ~H"""
    <table class="table table-sm">
      <thead>
        <tr>
          <th>{gettext("Date")}</th>
          <th>{gettext("Closed by")}</th>
          <th>{gettext("Post-close adjustment")}</th>
        </tr>
      </thead>
      <tbody>
        <tr :for={row <- @data}>
          <td>{row.z_report.business_date}</td>
          <td>{row.z_report.closed_by_membership_id}</td>
          <td>
            <span :if={row.adjustment} class="badge badge-warning badge-sm">{gettext("Adjusted")}</span>
            <span :if={!row.adjustment} class="text-base-content/40">—</span>
          </td>
        </tr>
        <tr :if={@data == []}>
          <td colspan="3" class="text-center text-base-content/50 py-4">
            {gettext("No closed business days in this period.")}
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp report_body(%{report_type: :profit} = assigns) do
    ~H"""
    <dl class="grid grid-cols-2 sm:grid-cols-3 gap-3 text-sm">
      <.stat label={gettext("Net revenue")}>
        <.money amount={@data.net_revenue} locale={@locale} />
      </.stat>
      <.stat label={gettext("Food cost")}><.money amount={@data.food_cost} locale={@locale} /></.stat>
      <.stat label={gettext("Gross profit")}>
        <.money amount={@data.gross_profit} locale={@locale} />
      </.stat>
      <.stat label={gettext("Purchases")}>
        <.money amount={@data.purchases_total} locale={@locale} />
      </.stat>
      <.stat label={gettext("Wastage")}>
        <.money amount={@data.wastage_total} locale={@locale} />
      </.stat>
      <.stat label={gettext("Platform fees")}>
        <.money amount={@data.platform_fees} locale={@locale} />
      </.stat>
    </dl>
    <p class="text-xs text-base-content/50 mt-4">
      {gettext(
        "Honest limit: labor, rent, and utilities aren't tracked — this is gross profit on food, not net profit."
      )}
    </p>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp stat(assigns) do
    ~H"""
    <div>
      <dt class="text-base-content/60">{@label}</dt>
      <dd class="font-semibold">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :label_fn, :any, required: true
  attr :value_fn, :any, required: true

  defp simple_list(assigns) do
    ~H"""
    <div>
      <h3 class="font-semibold text-sm mb-2">{@title}</h3>
      <p :if={@rows == []} class="text-sm text-base-content/50">{gettext("No data.")}</p>
      <ul :if={@rows != []} class="text-sm space-y-1">
        <li :for={row <- @rows} class="flex items-center justify-between">
          <span class="truncate">{@label_fn.(row)}</span>
          <span class="tabular-nums shrink-0 ml-2">{@value_fn.(row)}</span>
        </li>
      </ul>
    </div>
    """
  end

  defp last_year_sold(last_year_rows, menu_item_id) do
    case Enum.find(last_year_rows, &(&1.menu_item_id == menu_item_id)) do
      nil -> 0
      row -> row.sold
    end
  end

  defp trend_avg([]), do: "—"

  defp trend_avg(trend),
    do: trend |> Enum.map(& &1.avg) |> Enum.sum() |> Kernel./(length(trend)) |> Float.round(1)

  ## Mount / params

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:venues, Tenants.list_venues(scope))
     |> assign(:locale, scope.venue.locale)
     |> assign(:report_labels, @report_labels)
     |> assign(:subscription_frequencies, Reports.subscription_frequencies())
     |> assign(:subscriptions, Reports.list_subscriptions(scope))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope
    report_type = resolve_report_type(params["report"])
    {period, from_date, to_date} = resolve_period(scope.venue, params)

    {:noreply,
     socket
     |> assign(:report_type, report_type)
     |> assign(:period, period)
     |> assign(:from_date, from_date)
     |> assign(:to_date, to_date)
     |> assign(:data, Reports.generate(report_type, scope, from_date, to_date))}
  end

  @impl true
  def handle_event("pick_report", %{"report" => report}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/reports?#{[report: report, period: socket.assigns.period, from: Date.to_string(socket.assigns.from_date), to: Date.to_string(socket.assigns.to_date)]}"
     )}
  end

  def handle_event("set_custom_period", %{"from" => from, "to" => to}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         ~p"/reports?#{[report: socket.assigns.report_type, period: "custom", from: from, to: to]}"
     )}
  end

  def handle_event("subscribe", %{"frequency" => frequency}, socket) do
    scope = socket.assigns.current_scope

    case Reports.subscribe(scope, socket.assigns.report_type, String.to_existing_atom(frequency)) do
      {:ok, _subscription} ->
        {:noreply,
         socket
         |> assign(:subscriptions, Reports.list_subscriptions(scope))
         |> put_flash(:info, gettext("You'll receive this report by email."))}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You're already subscribed to this report at that frequency.")
         )}
    end
  end

  def handle_event("unsubscribe", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    Reports.unsubscribe(scope, id)
    {:noreply, assign(socket, :subscriptions, Reports.list_subscriptions(scope))}
  end

  defp resolve_report_type(nil), do: :revenue

  defp resolve_report_type(report) do
    atom = String.to_existing_atom(report)
    if atom in Reports.report_types(), do: atom, else: :revenue
  rescue
    ArgumentError -> :revenue
  end

  defp resolve_period(_venue, %{"from" => from, "to" => to})
       when from not in [nil, ""] and to not in [nil, ""] do
    {"custom", Date.from_iso8601!(from), Date.from_iso8601!(to)}
  end

  defp resolve_period(venue, %{"period" => period}) when period in @periods do
    {from_date, to_date} = period_dates(venue, period)
    {period, from_date, to_date}
  end

  defp resolve_period(venue, _params) do
    {from_date, to_date} = period_dates(venue, "7d")
    {"7d", from_date, to_date}
  end

  defp period_dates(venue, "today") do
    today = Tenants.business_date(venue)
    {today, today}
  end

  defp period_dates(venue, "30d") do
    today = Tenants.business_date(venue)
    {Date.add(today, -29), today}
  end

  defp period_dates(venue, "this_month") do
    today = Tenants.business_date(venue)
    {Date.beginning_of_month(today), today}
  end

  defp period_dates(venue, "this_year") do
    today = Tenants.business_date(venue)
    {Date.new!(today.year, 1, 1), today}
  end

  defp period_dates(venue, _seven_day) do
    today = Tenants.business_date(venue)
    {Date.add(today, -6), today}
  end
end

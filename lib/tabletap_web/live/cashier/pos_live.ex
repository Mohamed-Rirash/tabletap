defmodule TabletapWeb.Cashier.PosLive do
  @moduledoc """
  The cashier's register (build-plan.md Feature 15; ui-rules.md "Surface:
  Cashier POS" — "speed of entry is the metric"). Built entirely on top
  of the customer's own cart/checkout/payment machinery
  (`Tabletap.Ordering`, `Tabletap.Payments`) rather than a parallel POS
  data model: a ticket **is** a `Cart` with a cashier-minted
  `guest_token` held in socket state (never a URL param or session key —
  it only needs to survive this one LiveView process, unlike a
  customer's cookie-backed token), and "Charge" **is**
  `Ordering.checkout/2`, the exact one-way door the QR flow uses. This
  is the literal mechanism behind design-qa.md's "cashier as full
  customer proxy" — everything the QR flow can do, this can, because
  it's the same functions.

  Four screens, one LiveView, an `@overlay` assign (same shape as
  `Public.MenuLive`'s), never separate routes — a tablet register
  reloading between "ring up" and "take payment" would cost the one
  thing ui-rules.md says matters here, speed:
  - `:none` — category rail + search + item grid + the running ticket
  - `{:item, item, groups}` — modifier quick-sheet (mirrors the
    customer sheet's selection logic, denser layout for a tablet)
  - `{:payment, order}` — Cash / Wallet / Comp, discount entry, change
    calculator; a wallet charge stays on this screen showing "Waiting
    for the customer's PIN…" via the same `order:<id>` PubSub topic the
    tracker itself subscribes to
  - `:verify` — the Q3 pay-at-counter code lookup + Revive (Q26)

  Shift clock-in/out reuses `Tabletap.Staffing` unmodified (its own
  moduledoc already calls itself "a waiter/cashier clock-in/out window").
  """
  use TabletapWeb, :live_view

  alias Tabletap.{Catalog, Ordering, Payments, Staffing, Tenants}
  alias Tabletap.Ordering.{Cart, CartItem}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-6xl">
        <.header_bar
          venue_name={@current_scope.venue.name}
          on_shift={@on_shift}
          role={@current_scope.role}
        />

        <div :if={@on_shift} class="grid grid-cols-1 lg:grid-cols-3 gap-4">
          <div class="lg:col-span-2">
            <.search_and_rail
              categories={@categories}
              selected_category_id={@selected_category_id}
              search={@search}
            />
            <.item_grid
              items={@grid_items}
              locale={@current_scope.venue.locale}
              currency={@current_scope.venue.currency}
            />
          </div>

          <.ticket_panel
            cart={@cart}
            kind={@kind}
            table_id={@table_id}
            tables={@tables}
            locale={@current_scope.venue.locale}
            scope={@current_scope}
          />
        </div>

        <div :if={!@on_shift} class="rounded-box bg-base-100 border border-base-300 p-10 text-center">
          <.icon name="hero-calculator" class="size-10 mx-auto opacity-40" />
          <p class="mt-3 font-medium text-lg">{gettext("You're off shift")}</p>
          <p class="text-sm text-base-content/60">{gettext("Clock in to open the register.")}</p>
          <button type="button" phx-click="clock_in" class="btn btn-primary mt-4">
            {gettext("Start shift")}
          </button>
        </div>
      </div>

      <.item_sheet
        :if={match?({:item, _, _}, @overlay)}
        overlay={@overlay}
        selected_option_ids={@selected_option_ids}
        qty={@detail_qty}
        locale={@current_scope.venue.locale}
      />

      <.payment_sheet
        :if={match?({:payment, _}, @overlay)}
        overlay={@overlay}
        locale={@current_scope.venue.locale}
        discounts={@discounts}
        discount_form={@discount_form}
        comp_form={@comp_form}
        payment_error={@payment_error}
        role={@current_scope.role}
        cash_tendered={@cash_tendered}
        overlay_wallet_open?={@overlay_wallet_open?}
      />

      <.verify_sheet
        :if={@overlay == :verify}
        found_order={@found_order}
        verify_error={@verify_error}
        locale={@current_scope.venue.locale}
      />

      <.refund_sheet
        :if={@overlay == :refund}
        found_order={@found_refund_order}
        found_payment={@found_refund_payment}
        refund_error={@refund_error}
        locale={@current_scope.venue.locale}
      />

      <.shift_sheet
        :if={@overlay == :shift}
        summary={@shift_summary}
        locale={@current_scope.venue.locale}
      />
    </Layouts.app>
    """
  end

  ## Header

  attr :venue_name, :string, required: true
  attr :on_shift, :boolean, required: true
  attr :role, :atom, required: true

  defp header_bar(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3 mb-4 flex-wrap">
      <div>
        <h1 class="text-xl font-bold">{@venue_name}</h1>
        <p class="text-sm text-base-content/60">{gettext("Point of sale")}</p>
      </div>
      <div class="flex items-center gap-2">
        <button type="button" phx-click="open_verify" class="btn btn-outline btn-sm">
          <.icon name="hero-qr-code" class="size-4" /> {gettext("Verify cash order")}
        </button>
        <button type="button" phx-click="open_refund" class="btn btn-outline btn-sm">
          <.icon name="hero-arrow-uturn-left" class="size-4" /> {gettext("Refund")}
        </button>
        <button type="button" phx-click="open_shift" class="btn btn-outline btn-sm">
          <.icon name="hero-clock" class="size-4" /> {gettext("Shift")}
        </button>
        <.link navigate={~p"/pos/z-report"} class="btn btn-outline btn-sm">
          {gettext("Z-report")}
        </.link>
        <button :if={@on_shift} type="button" phx-click="clock_out" class="btn btn-ghost btn-sm">
          {gettext("End shift")}
        </button>
      </div>
    </div>
    """
  end

  ## Grid

  attr :categories, :list, required: true
  attr :selected_category_id, :any, required: true
  attr :search, :string, required: true

  defp search_and_rail(assigns) do
    ~H"""
    <div class="flex gap-2 mb-3 overflow-x-auto pb-1">
      <button
        type="button"
        phx-click="select_category"
        phx-value-id="all"
        class={["btn btn-sm shrink-0", is_nil(@selected_category_id) && "btn-primary"]}
      >
        {gettext("All")}
      </button>
      <button
        :for={{category, _items} <- @categories}
        type="button"
        phx-click="select_category"
        phx-value-id={category.id}
        class={["btn btn-sm shrink-0", @selected_category_id == category.id && "btn-primary"]}
      >
        {category.name}
      </button>
      <form id="pos-search-form" phx-change="search" class="ms-auto shrink-0">
        <input
          type="search"
          name="q"
          value={@search}
          placeholder={gettext("Search items…")}
          class="input input-sm w-48"
          phx-mounted={JS.focus()}
        />
      </form>
    </div>
    """
  end

  attr :items, :list, required: true
  attr :locale, :string, required: true
  attr :currency, :any, required: true

  defp item_grid(assigns) do
    ~H"""
    <div class="grid grid-cols-2 sm:grid-cols-3 xl:grid-cols-4 gap-3">
      <button
        :for={item <- @items}
        type="button"
        phx-click="open_item"
        phx-value-id={item.id}
        class="rounded-box bg-base-100 border border-base-300 p-2 text-start hover:border-brand transition-colors"
      >
        <div class="aspect-square rounded-field bg-base-200 mb-2 overflow-hidden">
          <img
            :if={item.photo_url}
            src={item.photo_url}
            alt=""
            class="w-full h-full object-cover"
          />
          <div :if={!item.photo_url} class="w-full h-full grid place-items-center opacity-30">
            <.icon name="hero-photo" class="size-8" />
          </div>
        </div>
        <p class="font-medium text-sm leading-snug line-clamp-2">{item.name}</p>
        <.money amount={item.price} locale={@locale} class="text-sm font-semibold text-brand" />
      </button>
      <p :if={@items == []} class="col-span-full text-center text-sm text-base-content/50 py-10">
        {gettext("No items match.")}
      </p>
    </div>
    """
  end

  ## Modifier quick-sheet — same domain rules as Public.MenuLive's item
  ## detail sheet (Ordering.unsatisfied_groups/2), denser layout.

  attr :overlay, :any, required: true
  attr :selected_option_ids, :any, required: true
  attr :qty, :integer, required: true
  attr :locale, :string, required: true

  defp item_sheet(assigns) do
    {:item, item, groups} = assigns.overlay
    assigns = assign(assigns, item: item, groups: groups)

    ~H"""
    <div class="fixed inset-0 z-50">
      <div class="absolute inset-0 bg-black/40" phx-click="close_overlay"></div>
      <div class="absolute inset-0 flex items-center justify-center p-4">
        <div class="pointer-events-auto bg-base-100 rounded-box w-full max-w-md max-h-[85vh] overflow-y-auto shadow-xl">
          <div class="p-4 border-b border-base-300 flex items-center justify-between">
            <h3 class="font-semibold text-lg">{@item.name}</h3>
            <button type="button" phx-click="close_overlay" class="btn btn-circle btn-sm btn-ghost">
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <div class="p-4 space-y-4">
            <div :for={group <- @groups} class="space-y-2">
              <p class="text-sm font-semibold">
                {group.name}
                <span class="text-base-content/50 font-normal">
                  ({gettext("pick %{min}-%{max}",
                    min: group.min_selections,
                    max: group.max_selections
                  )})
                </span>
              </p>
              <label
                :for={option <- Enum.filter(group.options, & &1.active)}
                class="flex items-center gap-2 py-1"
              >
                <input
                  type="checkbox"
                  class="checkbox checkbox-sm"
                  checked={MapSet.member?(@selected_option_ids, option.id)}
                  phx-click="toggle_option"
                  phx-value-group-id={group.id}
                  phx-value-option-id={option.id}
                />
                <span class="flex-1 text-sm">{option.name}</span>
                <.money
                  :if={
                    Money.compare!(option.price_delta, Money.new!(option.price_delta.currency, 0)) !=
                      :eq
                  }
                  amount={option.price_delta}
                  locale={@locale}
                  class="text-xs text-base-content/60"
                />
              </label>
            </div>

            <div class="flex items-center gap-3">
              <button type="button" phx-click="dec_qty" class="btn btn-circle btn-sm">−</button>
              <span class="font-semibold w-6 text-center">{@qty}</span>
              <button type="button" phx-click="inc_qty" class="btn btn-circle btn-sm">+</button>
            </div>
          </div>

          <div class="sticky bottom-0 bg-base-100 border-t border-base-300 p-4">
            <button type="button" phx-click="add_to_ticket" class="btn btn-primary w-full h-12">
              {gettext("Add to ticket")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  ## Ticket panel

  attr :cart, :any, required: true
  attr :kind, :atom, required: true
  attr :table_id, :any, required: true
  attr :tables, :list, required: true
  attr :locale, :string, required: true
  attr :scope, :any, required: true

  defp ticket_panel(assigns) do
    ~H"""
    <div class="rounded-box bg-base-100 border border-base-300 flex flex-col max-h-[80vh]">
      <div class="p-3 border-b border-base-300 space-y-2">
        <div class="join w-full">
          <button
            type="button"
            phx-click="set_kind"
            phx-value-kind="counter"
            class={[
              "btn btn-sm join-item flex-1",
              @kind == :counter && "bg-brand text-brand-content border-brand"
            ]}
          >
            {gettext("Walk-in")}
          </button>
          <button
            type="button"
            phx-click="set_kind"
            phx-value-kind="dine_in"
            class={[
              "btn btn-sm join-item flex-1",
              @kind == :dine_in && "bg-brand text-brand-content border-brand"
            ]}
          >
            {gettext("Dine in")}
          </button>
          <button
            type="button"
            phx-click="set_kind"
            phx-value-kind="takeaway"
            class={[
              "btn btn-sm join-item flex-1",
              @kind == :takeaway && "bg-brand text-brand-content border-brand"
            ]}
          >
            {gettext("Takeaway")}
          </button>
        </div>
        <select
          :if={@kind == :dine_in}
          name="table_id"
          phx-change="select_table"
          class="select select-sm w-full"
        >
          <option value="" selected={is_nil(@table_id)}>{gettext("Choose a table…")}</option>
          <option :for={table <- @tables} value={table.id} selected={@table_id == table.id}>
            {gettext("Table %{number}", number: table.number)}
          </option>
        </select>
      </div>

      <div class="flex-1 overflow-y-auto divide-y divide-base-200">
        <div :for={line <- (@cart && @cart.items) || []} class="p-3 flex items-start gap-2">
          <div class="flex-1 min-w-0">
            <p class="font-medium text-sm">{line.menu_item.name}</p>
            <p :for={option <- line.options} class="text-xs text-base-content/60 ps-2">
              {option.name}
            </p>
            <.money
              amount={Ordering.line_total(line)}
              locale={@locale}
              class="text-sm text-brand font-semibold"
            />
          </div>
          <div class="flex items-center gap-1 shrink-0">
            <button
              type="button"
              phx-click="dec_line_qty"
              phx-value-id={line.id}
              class="btn btn-circle btn-xs"
            >−</button>
            <span class="text-sm w-4 text-center">{line.qty}</span>
            <button
              type="button"
              phx-click="inc_line_qty"
              phx-value-id={line.id}
              class="btn btn-circle btn-xs"
            >+</button>
            <button
              type="button"
              phx-click="remove_line"
              phx-value-id={line.id}
              class="btn btn-circle btn-xs text-error"
            >
              <.icon name="hero-trash" class="size-3" />
            </button>
          </div>
        </div>
        <p :if={!@cart || @cart.items == []} class="p-6 text-center text-sm text-base-content/50">
          {gettext("Empty ticket — tap an item to add it.")}
        </p>
      </div>

      <div :if={@cart && @cart.items != []} class="p-3 border-t border-base-300 space-y-2">
        <div class="flex items-center justify-between">
          <span class="font-semibold">{gettext("Total")}</span>
          <.money
            amount={Ordering.cart_total(@scope, @cart)}
            locale={@locale}
            class="font-bold text-lg text-brand"
          />
        </div>
        <button
          type="button"
          phx-click="charge"
          disabled={@kind == :dine_in && is_nil(@table_id)}
          class="btn btn-primary w-full h-12"
        >
          {gettext("Charge")}
        </button>
      </div>
    </div>
    """
  end

  ## Payment screen

  attr :overlay, :any, required: true
  attr :locale, :string, required: true
  attr :discounts, :list, required: true
  attr :discount_form, :any, required: true
  attr :comp_form, :any, required: true
  attr :payment_error, :any, required: true
  attr :role, :atom, required: true
  attr :cash_tendered, :any, required: true
  attr :overlay_wallet_open?, :boolean, required: true

  defp payment_sheet(assigns) do
    {:payment, order} = assigns.overlay
    assigns = assign(assigns, order: order)

    ~H"""
    <div class="fixed inset-0 z-50 bg-black/40 flex items-center justify-center p-4">
      <div class="pointer-events-auto bg-base-100 rounded-box w-full max-w-md max-h-[90vh] overflow-y-auto shadow-xl">
        <div class="p-4 border-b border-base-300 flex items-center justify-between">
          <h3 class="font-semibold text-lg">{gettext("Order #%{number}", number: @order.number)}</h3>
          <button
            :if={@order.status == :pending_payment}
            type="button"
            phx-click="close_overlay"
            class="btn btn-circle btn-sm btn-ghost"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <div class="p-4 space-y-4">
          <div :for={discount <- @discounts} class="flex items-center justify-between text-sm">
            <span class="text-base-content/60">{discount.reason}</span>
            <span class="text-error">−<.money amount={discount.amount} locale={@locale} /></span>
          </div>

          <div class="flex items-center justify-between">
            <span class="font-semibold">{gettext("Total due")}</span>
            <.money amount={@order.total} locale={@locale} class="font-bold text-2xl text-brand" />
          </div>

          <p :if={@payment_error} class="text-sm text-error">{@payment_error}</p>

          <div :if={@order.status == :pending_payment}>
            <form
              id="pos-discount-form"
              phx-submit="apply_discount"
              phx-change="validate_discount"
              class="flex gap-2 items-end mb-4"
            >
              <.input
                field={@discount_form[:amount]}
                type="text"
                label={gettext("Discount")}
                placeholder="0.00"
              />
              <.input field={@discount_form[:reason]} type="text" label={gettext("Reason")} />
              <button type="submit" class="btn btn-outline btn-sm">{gettext("Apply")}</button>
            </form>

            <div class="grid grid-cols-2 gap-2 mb-3">
              <button type="button" phx-click="open_cash_tender" class="btn h-14 text-base">
                {gettext("Cash")}
              </button>
              <button type="button" phx-click="open_wallet" class="btn h-14 text-base">
                {gettext("Wallet")}
              </button>
            </div>

            <div :if={@cash_tendered != nil} class="rounded-box bg-base-200 p-3 mb-3 space-y-2">
              <form id="pos-tender-form" phx-change="tender_change" phx-submit="tender_change">
                <.input
                  name="tendered"
                  value={@cash_tendered}
                  type="text"
                  label={gettext("Cash received")}
                />
              </form>
              <p class="text-sm">
                {gettext("Change due:")}
                <span :if={change_due(@order.total, @cash_tendered)} class="font-semibold">
                  <.money amount={change_due(@order.total, @cash_tendered)} locale={@locale} />
                </span>
                <span :if={!change_due(@order.total, @cash_tendered)} class="font-semibold">—</span>
              </p>
              <button type="button" phx-click="pay_cash" class="btn btn-primary w-full">
                {gettext("Confirm cash payment")}
              </button>
            </div>

            <form
              :if={@overlay_wallet_open?}
              id="pos-wallet-form"
              phx-submit="pay_wallet"
              class="space-y-2 mb-3"
            >
              <.input
                name="wallet_msisdn"
                value=""
                type="tel"
                label={gettext("Wallet phone number")}
                placeholder="2526XXXXXXXX"
                required
              />
              <button type="submit" class="btn btn-primary w-full">{gettext("Send PIN prompt")}</button>
            </form>

            <div :if={@role in [:manager, :owner]} class="border-t border-base-300 pt-3">
              <form id="pos-comp-form" phx-submit="pay_comp" class="flex gap-2 items-end">
                <.input field={@comp_form[:reason]} type="text" label={gettext("Comp reason")} />
                <button type="submit" class="btn btn-outline btn-error btn-sm">{gettext("Comp")}</button>
              </form>
            </div>
          </div>

          <div :if={@order.status == :placed} class="text-center py-6">
            <.icon name="hero-check-circle" class="size-12 text-success mx-auto" />
            <p class="mt-2 font-semibold">{gettext("Paid — fired to the kitchen.")}</p>
            <button type="button" phx-click="new_ticket" class="btn btn-primary mt-4">
              {gettext("New ticket")}
            </button>
          </div>

          <div :if={@order.status not in [:pending_payment, :placed]} class="text-center py-6">
            <.icon name="hero-x-circle" class="size-12 text-error mx-auto" />
            <p class="mt-2 font-semibold">{gettext("Payment did not go through.")}</p>
            <button type="button" phx-click="close_overlay" class="btn btn-outline mt-4">
              {gettext("Back to ticket")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  ## Verify / Revive (Q3 / Q26)

  attr :found_order, :any, required: true
  attr :verify_error, :any, required: true
  attr :locale, :string, required: true

  defp verify_sheet(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 bg-black/40 flex items-center justify-center p-4">
      <div class="pointer-events-auto bg-base-100 rounded-box w-full max-w-sm shadow-xl">
        <div class="p-4 border-b border-base-300 flex items-center justify-between">
          <h3 class="font-semibold text-lg">{gettext("Verify cash order")}</h3>
          <button type="button" phx-click="close_overlay" class="btn btn-circle btn-sm btn-ghost">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <div class="p-4 space-y-3">
          <form id="pos-lookup-form" phx-submit="lookup_order">
            <.input
              name="number"
              value=""
              type="text"
              inputmode="numeric"
              label={gettext("Order number")}
              phx-mounted={JS.focus()}
              required
            />
            <button type="submit" class="btn btn-primary w-full mt-2">{gettext("Look up")}</button>
          </form>

          <p :if={@verify_error} class="text-sm text-error">{@verify_error}</p>

          <div :if={@found_order} class="rounded-box bg-base-200 p-3 space-y-2">
            <p class="font-semibold">{gettext("Order #%{number}", number: @found_order.number)}</p>
            <.money amount={@found_order.total} locale={@locale} class="font-bold text-brand" />
            <p :if={@found_order.status == :expired} class="text-sm text-warning">
              {gettext("This order's hold expired — Revive to bring it back.")}
            </p>
            <button
              :if={@found_order.status == :pending_payment}
              type="button"
              phx-click="verify_paid"
              class="btn btn-primary w-full"
            >
              {gettext("Verify paid")}
            </button>
            <button
              :if={@found_order.status == :expired}
              type="button"
              phx-click="verify_paid"
              class="btn btn-warning w-full"
            >
              {gettext("Revive & verify paid")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  ## Cash refunds (build-plan.md Feature 15 — "attributed refund row,
  ## reason required, subtracted from expected cash"). Cash only: a
  ## wallet refund is a different provider round-trip with no POS-side
  ## caller built yet, so this deliberately says so rather than silently
  ## mis-handling one.

  attr :found_order, :any, required: true
  attr :found_payment, :any, required: true
  attr :refund_error, :any, required: true
  attr :locale, :string, required: true

  defp refund_sheet(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 bg-black/40 flex items-center justify-center p-4">
      <div class="pointer-events-auto bg-base-100 rounded-box w-full max-w-sm shadow-xl">
        <div class="p-4 border-b border-base-300 flex items-center justify-between">
          <h3 class="font-semibold text-lg">{gettext("Refund")}</h3>
          <button type="button" phx-click="close_overlay" class="btn btn-circle btn-sm btn-ghost">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <div class="p-4 space-y-3">
          <form id="pos-refund-lookup-form" phx-submit="lookup_refund_order">
            <.input
              name="number"
              value=""
              type="text"
              inputmode="numeric"
              label={gettext("Order number")}
              phx-mounted={JS.focus()}
              required
            />
            <button type="submit" class="btn btn-primary w-full mt-2">{gettext("Look up")}</button>
          </form>

          <p :if={@refund_error} class="text-sm text-error">{@refund_error}</p>

          <div :if={@found_order && !@found_payment} class="rounded-box bg-base-200 p-3">
            <p class="text-sm text-base-content/60">
              {gettext("Order #%{number} has no payment to refund.", number: @found_order.number)}
            </p>
          </div>

          <div
            :if={@found_order && @found_payment && @found_payment.provider != :cash}
            class="rounded-box bg-base-200 p-3"
          >
            <p class="text-sm text-base-content/60">
              {gettext(
                "Order #%{number} was paid by %{provider} — only cash refunds are handled here; ask a manager for other refunds.",
                number: @found_order.number,
                provider: @found_payment.provider
              )}
            </p>
          </div>

          <div
            :if={@found_order && @found_payment && @found_payment.provider == :cash}
            class="rounded-box bg-base-200 p-3 space-y-2"
          >
            <p class="font-semibold">{gettext("Order #%{number}", number: @found_order.number)}</p>
            <.money amount={@found_payment.amount} locale={@locale} class="font-bold text-brand" />

            <form id="pos-refund-form" phx-submit="submit_refund" class="space-y-2 pt-2">
              <.input
                name="amount"
                value={Money.to_decimal(@found_payment.amount) |> Decimal.to_string()}
                type="text"
                label={gettext("Refund amount")}
                required
              />
              <.input name="reason" value="" type="text" label={gettext("Reason")} required />
              <button type="submit" class="btn btn-primary w-full">
                {gettext("Refund cash")}
              </button>
            </form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  ## Shift summary

  attr :summary, :any, required: true
  attr :locale, :string, required: true

  defp shift_sheet(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 bg-black/40 flex items-center justify-center p-4">
      <div class="pointer-events-auto bg-base-100 rounded-box w-full max-w-sm shadow-xl">
        <div class="p-4 border-b border-base-300 flex items-center justify-between">
          <h3 class="font-semibold text-lg">{gettext("Shift summary")}</h3>
          <button type="button" phx-click="close_overlay" class="btn btn-circle btn-sm btn-ghost">
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
        <div class="p-4 space-y-2">
          <div class="flex items-center justify-between">
            <span class="text-base-content/60">{gettext("Transactions today")}</span>
            <span class="font-semibold">{@summary.transaction_count}</span>
          </div>
          <div class="flex items-center justify-between">
            <span class="text-base-content/60">{gettext("Cash taken")}</span>
            <.money amount={@summary.cash_taken} locale={@locale} class="font-semibold" />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp change_due(total, tendered_str) do
    case Decimal.parse(tendered_str || "") do
      {tendered, _} ->
        tendered_money = Money.new!(total.currency, tendered)

        if Money.compare!(tendered_money, total) == :lt,
          do: nil,
          else: Money.sub!(tendered_money, total)

      :error ->
        nil
    end
  end

  ## Mount / events

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    on_shift = Staffing.get_open_shift(scope) != nil

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:on_shift, on_shift)
     |> assign(:ticket_token, Cart.generate_guest_token())
     |> assign(:categories, Catalog.list_public_menu(scope))
     |> assign(:selected_category_id, nil)
     |> assign(:search, "")
     |> assign(:kind, :counter)
     |> assign(:table_id, nil)
     |> assign(:tables, Tenants.list_tables(scope))
     |> assign(:overlay, :none)
     |> assign(:selected_option_ids, MapSet.new())
     |> assign(:detail_qty, 1)
     |> assign(:discounts, [])
     |> assign(:discount_form, to_form(%{"amount" => "", "reason" => ""}, as: "discount"))
     |> assign(:comp_form, to_form(%{"reason" => ""}, as: "comp"))
     |> assign(:payment_error, nil)
     |> assign(:overlay_wallet_open?, false)
     |> assign(:cash_tendered, nil)
     |> assign(:found_order, nil)
     |> assign(:verify_error, nil)
     |> assign(:found_refund_order, nil)
     |> assign(:found_refund_payment, nil)
     |> assign(:refund_error, nil)
     |> assign(:shift_summary, nil)
     |> reload_cart()}
  end

  @impl true
  def handle_event("clock_in", _params, socket) do
    {:ok, _shift} = Staffing.clock_in(socket.assigns.current_scope)
    {:noreply, assign(socket, :on_shift, true)}
  end

  def handle_event("clock_out", _params, socket) do
    {:ok, _shift} = Staffing.clock_out(socket.assigns.current_scope)
    {:noreply, assign(socket, :on_shift, false)}
  end

  def handle_event("select_category", %{"id" => "all"}, socket) do
    {:noreply, socket |> assign(:selected_category_id, nil) |> assign_grid_items()}
  end

  def handle_event("select_category", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:selected_category_id, id) |> assign_grid_items()}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:search, q) |> assign_grid_items()}
  end

  # ui-rules.md "Surface: Cashier POS" — "Tapping an item with required
  # modifiers opens the modifier sheet; items without go straight to the
  # ticket." A no-modifier item (the common case — a plain coffee, a
  # pastry) skips the sheet entirely: one tap, one line on the ticket,
  # matching the surface's own "speed of entry is the metric" mandate.
  def handle_event("open_item", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    item = Catalog.get_item(scope, id)
    groups = Catalog.list_item_modifier_groups(scope, item)

    case groups do
      [] ->
        {:noreply, do_add_to_ticket(socket, item, [], 1)}

      groups ->
        default_ids =
          groups
          |> Enum.flat_map(& &1.options)
          |> Enum.filter(& &1.default)
          |> Enum.map(& &1.id)
          |> MapSet.new()

        {:noreply,
         socket
         |> assign(:overlay, {:item, item, groups})
         |> assign(:selected_option_ids, default_ids)
         |> assign(:detail_qty, 1)}
    end
  end

  def handle_event("close_overlay", _params, socket) do
    {:noreply,
     socket
     |> assign(:overlay, :none)
     |> assign(:payment_error, nil)
     |> assign(:overlay_wallet_open?, false)
     |> assign(:cash_tendered, nil)
     |> assign(:found_order, nil)
     |> assign(:verify_error, nil)
     |> assign(:found_refund_order, nil)
     |> assign(:found_refund_payment, nil)
     |> assign(:refund_error, nil)}
  end

  def handle_event("toggle_option", %{"group-id" => group_id, "option-id" => option_id}, socket) do
    {:item, _item, groups} = socket.assigns.overlay
    group = Enum.find(groups, &(&1.id == group_id))
    selected = socket.assigns.selected_option_ids

    {:noreply, assign(socket, :selected_option_ids, toggle_selection(group, option_id, selected))}
  end

  def handle_event("inc_qty", _params, socket) do
    {:noreply, update(socket, :detail_qty, &min(&1 + 1, CartItem.max_qty()))}
  end

  def handle_event("dec_qty", _params, socket) do
    {:noreply, update(socket, :detail_qty, &max(&1 - 1, 1))}
  end

  def handle_event("add_to_ticket", _params, socket) do
    {:item, item, _groups} = socket.assigns.overlay
    option_ids = MapSet.to_list(socket.assigns.selected_option_ids)

    {:noreply, do_add_to_ticket(socket, item, option_ids, socket.assigns.detail_qty)}
  end

  def handle_event("set_kind", %{"kind" => kind}, socket) do
    kind = String.to_existing_atom(kind)
    socket = assign(socket, :kind, kind)

    {:noreply,
     if(socket.assigns.cart, do: socket |> ensure_cart_kind() |> reload_cart(), else: socket)}
  end

  def handle_event("select_table", %{"table_id" => ""}, socket),
    do: {:noreply, assign(socket, :table_id, nil)}

  def handle_event("select_table", %{"table_id" => id}, socket),
    do: {:noreply, assign(socket, :table_id, id)}

  def handle_event("inc_line_qty", %{"id" => id}, socket), do: bump_line_qty(socket, id, 1)
  def handle_event("dec_line_qty", %{"id" => id}, socket), do: bump_line_qty(socket, id, -1)

  def handle_event("remove_line", %{"id" => id}, socket) do
    line = Enum.find(socket.assigns.cart.items, &(&1.id == id))
    :ok = Ordering.remove_item(socket.assigns.current_scope, line)
    {:noreply, reload_cart(socket)}
  end

  def handle_event("charge", _params, socket) do
    scope = socket.assigns.current_scope

    case Ordering.checkout(scope, socket.assigns.cart) do
      {:ok, order} ->
        if connected?(socket), do: Phoenix.PubSub.subscribe(Tabletap.PubSub, "order:#{order.id}")

        {:noreply,
         socket
         |> assign(:overlay, {:payment, order})
         |> assign(:discounts, Ordering.list_discounts(scope, order))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, checkout_error_message(reason))}
    end
  end

  def handle_event("validate_discount", %{"discount" => params}, socket) do
    {:noreply, assign(socket, :discount_form, to_form(params, as: "discount"))}
  end

  def handle_event(
        "apply_discount",
        %{"discount" => %{"amount" => amount_str, "reason" => reason}},
        socket
      ) do
    {:payment, order} = socket.assigns.overlay
    scope = socket.assigns.current_scope

    with {decimal, _} <- Decimal.parse(amount_str),
         amount = Money.new!(order.total.currency, decimal),
         {:ok, updated_order} <-
           Ordering.apply_discount(
             scope,
             order,
             %{amount: amount, reason: reason},
             scope.membership
           ) do
      {:noreply,
       socket
       |> assign(:overlay, {:payment, updated_order})
       |> assign(:discounts, Ordering.list_discounts(scope, updated_order))
       |> assign(:discount_form, to_form(%{"amount" => "", "reason" => ""}, as: "discount"))}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Couldn't apply that discount."))}
    end
  end

  def handle_event("open_cash_tender", _params, socket),
    do: {:noreply, assign(socket, :cash_tendered, "")}

  def handle_event("tender_change", %{"tendered" => tendered}, socket),
    do: {:noreply, assign(socket, :cash_tendered, tendered)}

  def handle_event("pay_cash", _params, socket) do
    {:payment, order} = socket.assigns.overlay
    scope = socket.assigns.current_scope

    case Payments.settle_cash_now(scope, order, scope.membership) do
      {:ok, _payment} ->
        {:noreply, assign(socket, :overlay, {:payment, Ordering.get_order(scope, order.id)})}

      {:error, _reason} ->
        {:noreply, assign(socket, :payment_error, gettext("Couldn't settle the cash payment."))}
    end
  end

  def handle_event("open_wallet", _params, socket),
    do: {:noreply, assign(socket, :overlay_wallet_open?, true)}

  def handle_event("pay_wallet", %{"wallet_msisdn" => msisdn}, socket) do
    {:payment, order} = socket.assigns.overlay
    scope = socket.assigns.current_scope

    case Payments.charge_order(scope, order, msisdn) do
      {:ok, _payment} ->
        {:noreply, socket |> assign(:overlay_wallet_open?, false) |> assign(:payment_error, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :payment_error, checkout_error_message(reason))}
    end
  end

  def handle_event("pay_comp", %{"comp" => %{"reason" => reason}}, socket) do
    {:payment, order} = socket.assigns.overlay
    scope = socket.assigns.current_scope

    case Payments.charge_comp(scope, order, reason, scope.membership) do
      {:ok, _payment} ->
        {:noreply, assign(socket, :overlay, {:payment, Ordering.get_order(scope, order.id)})}

      {:error, :requires_manager} ->
        {:noreply, assign(socket, :payment_error, gettext("Only a manager can comp an order."))}

      {:error, _reason} ->
        {:noreply, assign(socket, :payment_error, gettext("Couldn't comp this order."))}
    end
  end

  def handle_event("new_ticket", _params, socket) do
    {:noreply,
     socket
     |> assign(:overlay, :none)
     |> assign(:ticket_token, Cart.generate_guest_token())
     |> assign(:kind, :counter)
     |> assign(:table_id, nil)
     |> assign(:discounts, [])
     |> reload_cart()}
  end

  def handle_event("open_verify", _params, socket) do
    {:noreply,
     socket
     |> assign(:overlay, :verify)
     |> assign(:found_order, nil)
     |> assign(:verify_error, nil)}
  end

  def handle_event("lookup_order", %{"number" => number_str}, socket) do
    case Integer.parse(number_str) do
      {number, _} ->
        case Ordering.get_order_by_number(socket.assigns.current_scope, number) do
          nil ->
            {:noreply,
             assign(socket, verify_error: gettext("No matching order today."), found_order: nil)}

          order ->
            {:noreply, assign(socket, found_order: order, verify_error: nil)}
        end

      :error ->
        {:noreply, assign(socket, verify_error: gettext("Enter a valid order number."))}
    end
  end

  def handle_event("verify_paid", _params, socket) do
    scope = socket.assigns.current_scope
    order = socket.assigns.found_order

    case Payments.verify_cash_payment(scope, order, scope.membership) do
      {:ok, _payment} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Order #%{number} verified and fired.", number: order.number)
         )
         |> assign(:overlay, :none)
         |> assign(:found_order, nil)}

      {:error, {:sold_out, item_name}} ->
        {:noreply, assign(socket, :verify_error, sold_out_message(item_name))}

      {:error, _reason} ->
        {:noreply, assign(socket, :verify_error, gettext("Couldn't verify this order."))}
    end
  end

  def handle_event("open_refund", _params, socket) do
    {:noreply,
     socket
     |> assign(:overlay, :refund)
     |> assign(:found_refund_order, nil)
     |> assign(:found_refund_payment, nil)
     |> assign(:refund_error, nil)}
  end

  def handle_event("lookup_refund_order", %{"number" => number_str}, socket) do
    scope = socket.assigns.current_scope

    case Integer.parse(number_str) do
      {number, _} ->
        case Ordering.get_any_order_by_number(scope, number) do
          nil ->
            {:noreply,
             socket
             |> assign(:refund_error, gettext("No matching order today."))
             |> assign(:found_refund_order, nil)
             |> assign(:found_refund_payment, nil)}

          order ->
            payment = Payments.get_latest_payment_for_order(scope, order.id)

            {:noreply,
             socket
             |> assign(:found_refund_order, order)
             |> assign(:found_refund_payment, refundable_payment(payment))
             |> assign(:refund_error, nil)}
        end

      :error ->
        {:noreply, assign(socket, :refund_error, gettext("Enter a valid order number."))}
    end
  end

  def handle_event("submit_refund", %{"amount" => amount_str, "reason" => reason}, socket) do
    scope = socket.assigns.current_scope
    payment = socket.assigns.found_refund_payment
    order = socket.assigns.found_refund_order

    with {decimal, ""} <- Decimal.parse(amount_str),
         amount = Money.new!(payment.amount.currency, decimal),
         {:ok, _refund} <- Payments.refund(scope, payment, amount, reason, scope.user.id) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Refunded order #%{number}.", number: order.number))
       |> assign(:overlay, :none)
       |> assign(:found_refund_order, nil)
       |> assign(:found_refund_payment, nil)}
    else
      {:error, :over_refund} ->
        {:noreply,
         assign(socket, :refund_error, gettext("That's more than what's left to refund."))}

      _other ->
        {:noreply,
         assign(socket, :refund_error, gettext("That doesn't look like a valid amount."))}
    end
  end

  def handle_event("open_shift", _params, socket) do
    scope = socket.assigns.current_scope
    summary = Payments.cashier_summary(scope, scope.membership)
    {:noreply, socket |> assign(:overlay, :shift) |> assign(:shift_summary, summary)}
  end

  @impl true
  def handle_info(:order_updated, socket) do
    case socket.assigns.overlay do
      {:payment, order} ->
        updated = Ordering.get_order(socket.assigns.current_scope, order.id)
        {:noreply, assign(socket, :overlay, {:payment, updated})}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Helpers

  # Only a `succeeded` payment has anything left to give back — a
  # `pending`/`failed`/already fully-`refunded` one has nothing to
  # refund, same message as "no payment at all" (the template doesn't
  # need to tell those apart).
  defp refundable_payment(%Payments.Payment{status: :succeeded} = payment), do: payment
  defp refundable_payment(_payment), do: nil

  # Shared by the no-modifier fast path (`open_item` with `groups == []`)
  # and the modifier sheet's own "Add to ticket" submit — one place that
  # actually calls `Ordering.add_to_cart/7`, so the two paths can never
  # drift on what a successful add does.
  defp do_add_to_ticket(socket, item, option_ids, qty) do
    scope = socket.assigns.current_scope
    table_id = if socket.assigns.kind == :dine_in, do: socket.assigns.table_id, else: nil

    case Ordering.add_to_cart(
           scope,
           socket.assigns.ticket_token,
           table_id,
           item,
           option_ids,
           qty,
           nil
         ) do
      {:ok, _cart} ->
        socket |> assign(:overlay, :none) |> reload_cart() |> ensure_cart_kind()

      {:error, _reason} ->
        put_flash(socket, :error, gettext("Couldn't add that item — it may have just sold out."))
    end
  end

  defp reload_cart(socket) do
    scope = socket.assigns.current_scope
    cart = Ordering.get_active_cart(scope, socket.assigns.ticket_token)
    socket |> assign(:cart, cart) |> assign_grid_items()
  end

  defp ensure_cart_kind(socket) do
    scope = socket.assigns.current_scope

    case socket.assigns.cart do
      %Cart{kind: kind} = cart when kind != socket.assigns.kind ->
        {:ok, _cart} = Ordering.set_kind(scope, cart, socket.assigns.kind)
        socket

      _other ->
        socket
    end
  end

  defp assign_grid_items(socket) do
    items =
      socket.assigns.categories
      |> filter_by_category(socket.assigns.selected_category_id)
      |> Enum.flat_map(fn {_category, items} -> items end)
      |> filter_by_search(socket.assigns.search)

    assign(socket, :grid_items, items)
  end

  defp filter_by_category(categories, nil), do: categories

  defp filter_by_category(categories, id),
    do: Enum.filter(categories, fn {c, _items} -> c.id == id end)

  defp filter_by_search(items, ""), do: items

  defp filter_by_search(items, q) do
    q = String.downcase(q)
    Enum.filter(items, &String.contains?(String.downcase(&1.name), q))
  end

  defp bump_line_qty(socket, id, delta) do
    scope = socket.assigns.current_scope
    line = Enum.find(socket.assigns.cart.items, &(&1.id == id))
    new_qty = max(line.qty + delta, 1)

    case Ordering.update_item(scope, line, %{"qty" => new_qty}) do
      {:ok, _line} -> {:noreply, reload_cart(socket)}
      {:error, _changeset} -> {:noreply, socket}
    end
  end

  defp toggle_selection(%{max_selections: 1}, option_id, _selected), do: MapSet.new([option_id])

  defp toggle_selection(_group, option_id, selected) do
    if MapSet.member?(selected, option_id),
      do: MapSet.delete(selected, option_id),
      else: MapSet.put(selected, option_id)
  end

  defp checkout_error_message(:venue_closed), do: gettext("The venue is closed right now.")
  defp checkout_error_message(:ordering_paused), do: gettext("Ordering is paused right now.")
  defp checkout_error_message(:empty_cart), do: gettext("The ticket is empty.")

  defp checkout_error_message(:too_many_active_orders),
    do: gettext("Too many open orders for this ticket.")

  defp checkout_error_message(:items_changed),
    do: gettext("An item's options changed — remove and re-add it.")

  defp checkout_error_message(:sold_out), do: gettext("Something on this ticket just sold out.")

  defp checkout_error_message(:charges_not_enabled),
    do: gettext("This venue isn't set up for wallet payments yet.")

  defp checkout_error_message(_other), do: gettext("Something went wrong — please try again.")

  defp sold_out_message(nil),
    do: gettext("Sold out while the hold expired — rebuild the order with the customer.")

  defp sold_out_message(item_name),
    do:
      gettext("%{item} sold out while the hold expired — rebuild the order with the customer.",
        item: item_name
      )
end

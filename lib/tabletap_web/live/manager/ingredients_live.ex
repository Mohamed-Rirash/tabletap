defmodule TabletapWeb.Manager.IngredientsLive do
  @moduledoc """
  Manager-facing ingredient library (build-plan.md Feature 12) plus
  stock operations (Feature 13): create/edit/archive ingredients, and
  per-ingredient restock/adjust/wastage quick actions — all as
  `stock_movements` rows. Recipe attachment lives on
  `TabletapWeb.Manager.MenuLive`'s item modal, same split
  `Manager.ModifiersLive`/`Manager.MenuLive` already use for modifier
  groups (reusable library here, per-item attachment there).

  Low-stock/negative-stock banners subscribe to `venue:<id>:inventory`
  (`Inventory.restock/5`/`adjust_stock/4`/`log_wastage/4`/
  `deduct_for_order/2` all broadcast there) so a live drop below
  threshold pings this page without a refresh — the build-plan verify
  step's "dropping cheese below threshold pings the manager dashboard
  live."
  """
  use TabletapWeb, :live_view

  alias Tabletap.Inventory
  alias Tabletap.Inventory.{Ingredient, UnitInput}
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
        <h1 class="text-2xl font-bold">{gettext("Inventory")}</h1>
        <div class="flex items-center gap-2">
          <.link navigate={~p"/inventory/stocktake"} class="btn btn-outline btn-sm">
            {gettext("Stocktake")}
          </.link>
          <.link navigate={~p"/inventory/restock"} class="btn btn-outline btn-sm">
            {gettext("Restock report")}
          </.link>
        </div>
      </div>
      <p class="text-sm text-base-content/60 mb-6 max-w-prose">
        {gettext(
          "Ingredients, stock levels, and thresholds. Attach a recipe to a menu item from the menu editor."
        )}
      </p>

      <div :if={@low_stock != []} class="mb-4 rounded-box bg-warning/10 border border-warning/40 p-4">
        <p class="font-semibold flex items-center gap-2">
          <.icon name="hero-exclamation-triangle" class="size-4 text-warning" />
          {gettext("Low stock: %{names}", names: Enum.map_join(@low_stock, ", ", & &1.name))}
        </p>
      </div>

      <div :if={@negative_stock != []} class="mb-6 rounded-box bg-error/10 border border-error/40 p-4">
        <p class="font-semibold flex items-center gap-2">
          <.icon name="hero-exclamation-circle" class="size-4 text-error" />
          {gettext("Negative stock (needs reconciling): %{names}",
            names: Enum.map_join(@negative_stock, ", ", & &1.name)
          )}
        </p>
      </div>

      <form
        id="ingredient-form"
        phx-submit="save_ingredient"
        phx-change="validate_ingredient"
        class="mb-8 rounded-box bg-base-100 shadow-sm p-5"
      >
        <h2 class="font-semibold mb-3">
          {if @ingredient_form_mode == :new,
            do: gettext("New ingredient"),
            else: gettext("Edit ingredient")}
        </h2>
        <div class="grid gap-3 sm:grid-cols-4 items-end">
          <.input
            field={@ingredient_form[:name]}
            type="text"
            label={gettext("Name")}
            placeholder={gettext("e.g. Cheddar cheese")}
          />
          <div class="fieldset mb-2">
            <label for="ingredient-unit">
              <span class="label mb-1">{gettext("Base unit")}</span>
              <select id="ingredient-unit" name="ingredient[unit]" class="w-full select">
                <option
                  :for={unit <- Ingredient.units()}
                  value={unit}
                  selected={to_string(unit) == to_string(@ingredient_form[:unit].value)}
                >
                  {unit}
                </option>
              </select>
            </label>
          </div>
          <div class="fieldset mb-2">
            <label for="ingredient-threshold">
              <span class="label mb-1">{gettext("Low-stock threshold")}</span>
              <input
                type="text"
                id="ingredient-threshold"
                name="ingredient[min_threshold_input]"
                value={@ingredient_form.params["min_threshold_input"]}
                placeholder={gettext("e.g. 1.5kg")}
                class="w-full input"
              />
              <p
                :for={msg <- translate_errors(@ingredient_form.source.errors, :min_threshold)}
                class="mt-1.5 flex gap-2 items-center text-sm text-error"
              >
                <.icon name="hero-exclamation-circle" class="size-5" /> {msg}
              </p>
            </label>
          </div>
          <div class="fieldset mb-2">
            <label for="ingredient-cost">
              <span class="label mb-1">{gettext("Cost per unit")}</span>
              <input
                type="text"
                id="ingredient-cost"
                name="ingredient[cost_amount]"
                value={@ingredient_form.params["cost_amount"]}
                inputmode="decimal"
                placeholder="0.00"
                class="w-full input"
              />
              <p
                :for={msg <- translate_errors(@ingredient_form.source.errors, :cost_per_unit)}
                class="mt-1.5 flex gap-2 items-center text-sm text-error"
              >
                <.icon name="hero-exclamation-circle" class="size-5" /> {msg}
              </p>
            </label>
          </div>
        </div>
        <div class="flex gap-2 mt-3">
          <button type="submit" class="btn btn-primary btn-sm">
            {if @ingredient_form_mode == :new,
              do: gettext("Add ingredient"),
              else: gettext("Save changes")}
          </button>
          <button
            :if={@ingredient_form_mode != :new}
            type="button"
            phx-click="cancel_ingredient_edit"
            class="btn btn-ghost btn-sm"
          >
            {gettext("Cancel")}
          </button>
        </div>
      </form>

      <div class="space-y-3">
        <div
          :for={ingredient <- @ingredients}
          id={"ingredient-#{ingredient.id}"}
          class={[
            "rounded-box bg-base-100 shadow-sm p-4",
            Inventory.low_stock?(ingredient) && "border border-warning/40"
          ]}
        >
          <div class="flex items-center justify-between gap-3 flex-wrap">
            <div class="flex items-center gap-2 flex-wrap min-w-0">
              <span class="font-semibold">{ingredient.name}</span>
              <span class="badge badge-ghost badge-sm">
                {Decimal.to_string(ingredient.stock_qty)} {ingredient.unit}
              </span>
              <span :if={Inventory.low_stock?(ingredient)} class="badge badge-warning badge-sm">
                {gettext("Low")}
              </span>
              <span :if={Decimal.negative?(ingredient.stock_qty)} class="badge badge-error badge-sm">
                {gettext("Negative")}
              </span>
            </div>
            <div class="flex items-center gap-2">
              <button
                type="button"
                phx-click="open_action"
                phx-value-kind="restock"
                phx-value-id={ingredient.id}
                class="btn btn-xs btn-outline"
              >
                {gettext("Restock")}
              </button>
              <button
                type="button"
                phx-click="open_action"
                phx-value-kind="adjust"
                phx-value-id={ingredient.id}
                class="btn btn-xs btn-outline"
              >
                {gettext("Adjust")}
              </button>
              <button
                type="button"
                phx-click="open_action"
                phx-value-kind="wastage"
                phx-value-id={ingredient.id}
                class="btn btn-xs btn-outline"
              >
                {gettext("Waste")}
              </button>
              <button
                type="button"
                phx-click="edit_ingredient"
                phx-value-id={ingredient.id}
                class="btn btn-xs btn-ghost"
              >
                {gettext("Edit")}
              </button>
              <button
                type="button"
                phx-click="archive_ingredient"
                phx-value-id={ingredient.id}
                data-confirm={
                  gettext(
                    "Archive this ingredient? It'll be hidden from recipes and restock pickers."
                  )
                }
                class="btn btn-xs btn-ghost text-error"
              >
                {gettext("Archive")}
              </button>
            </div>
          </div>

          <.action_form
            :if={@action_target && elem(@action_target, 1) == ingredient.id}
            kind={elem(@action_target, 0)}
            ingredient={ingredient}
            form={@action_form}
          />
        </div>

        <p :if={@ingredients == []} class="text-sm text-base-content/50">
          {gettext("No ingredients yet — add one above to get started.")}
        </p>
      </div>
    </Layouts.manager>
    """
  end

  attr :kind, :atom, required: true
  attr :ingredient, :any, required: true
  attr :form, :any, required: true

  defp action_form(assigns) do
    ~H"""
    <form
      id={"action-form-#{@ingredient.id}"}
      phx-submit="save_action"
      class="mt-3 rounded-field bg-base-200/60 p-3 grid gap-3 sm:grid-cols-3 items-end"
    >
      <div class="fieldset mb-2">
        <label for={"action-qty-#{@ingredient.id}"}>
          <span class="label mb-1">{action_qty_label(@kind)}</span>
          <input
            type="text"
            id={"action-qty-#{@ingredient.id}"}
            name="action[qty_input]"
            value={@form.params["qty_input"]}
            placeholder={gettext("e.g. 2kg")}
            class="w-full input"
          />
        </label>
      </div>
      <div :if={@kind == :restock} class="fieldset mb-2">
        <label for={"action-cost-#{@ingredient.id}"}>
          <span class="label mb-1">{gettext("Price paid (per unit)")}</span>
          <input
            type="text"
            id={"action-cost-#{@ingredient.id}"}
            name="action[cost_amount]"
            value={@form.params["cost_amount"]}
            inputmode="decimal"
            placeholder="0.00"
            class="w-full input"
          />
        </label>
      </div>
      <div :if={@kind in [:adjust, :wastage]} class="fieldset mb-2">
        <label for={"action-note-#{@ingredient.id}"}>
          <span class="label mb-1">{gettext("Reason")}</span>
          <input
            type="text"
            id={"action-note-#{@ingredient.id}"}
            name="action[note]"
            value={@form.params["note"]}
            class="w-full input"
          />
        </label>
      </div>
      <p :for={{_field, {msg, _opts}} <- @form.source.errors} class="text-sm text-error sm:col-span-3">
        {msg}
      </p>
      <div class="flex gap-2 sm:col-span-3">
        <button type="submit" class="btn btn-sm btn-primary">{gettext("Save")}</button>
        <button type="button" phx-click="cancel_action" class="btn btn-sm btn-ghost">
          {gettext("Cancel")}
        </button>
      </div>
    </form>
    """
  end

  defp action_qty_label(:restock), do: gettext("Quantity received")
  defp action_qty_label(:adjust), do: gettext("Adjustment (+/-)")
  defp action_qty_label(:wastage), do: gettext("Quantity wasted")

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{scope.venue.id}:inventory")
    end

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:venues, Tenants.list_venues(scope))
     |> assign(
       :ingredient_form,
       to_form(Ingredient.creation_changeset(%Ingredient{}, %{}), as: :ingredient)
     )
     |> assign(:ingredient_form_mode, :new)
     |> assign(:action_target, nil)
     |> assign(:action_form, nil)
     |> reload()}
  end

  ## Ingredient CRUD

  @impl true
  def handle_event("validate_ingredient", %{"ingredient" => params}, socket) do
    changeset = socket |> ingredient_changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :ingredient_form, to_form(changeset, as: :ingredient))}
  end

  def handle_event("save_ingredient", %{"ingredient" => params}, socket) do
    scope = socket.assigns.current_scope
    unit = unit_from_params(socket, params)

    with {:ok, threshold} <- parse_threshold(unit, params["min_threshold_input"]),
         {:ok, cost} <- parse_cost(params["cost_amount"], scope.venue.currency) do
      attrs = params |> Map.put("min_threshold", threshold) |> Map.put("cost_per_unit", cost)
      do_save_ingredient(socket, attrs)
    else
      {:error, field, message} ->
        changeset =
          socket
          |> ingredient_changeset(params)
          |> Ecto.Changeset.add_error(field, message)
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :ingredient_form, to_form(changeset, as: :ingredient))}
    end
  end

  def handle_event("edit_ingredient", %{"id" => id}, socket) do
    ingredient = find_ingredient(socket, id)

    changeset =
      Ingredient.update_changeset(ingredient, %{
        "min_threshold_input" => threshold_input(ingredient),
        "cost_amount" => cost_input(ingredient)
      })

    {:noreply,
     socket
     |> assign(:ingredient_form, to_form(changeset, as: :ingredient))
     |> assign(:ingredient_form_mode, {:edit, id})}
  end

  def handle_event("cancel_ingredient_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(
       :ingredient_form,
       to_form(Ingredient.creation_changeset(%Ingredient{}, %{}), as: :ingredient)
     )
     |> assign(:ingredient_form_mode, :new)}
  end

  def handle_event("archive_ingredient", %{"id" => id}, socket) do
    {:ok, _} =
      Inventory.archive_ingredient(socket.assigns.current_scope, find_ingredient(socket, id))

    {:noreply, reload(socket)}
  end

  ## Stock-op quick actions

  def handle_event("open_action", %{"kind" => kind, "id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:action_target, {String.to_existing_atom(kind), id})
     |> assign(:action_form, to_form(%{}, as: :action))}
  end

  def handle_event("cancel_action", _params, socket) do
    {:noreply, socket |> assign(:action_target, nil) |> assign(:action_form, nil)}
  end

  def handle_event("save_action", %{"action" => params}, socket) do
    {kind, id} = socket.assigns.action_target
    ingredient = find_ingredient(socket, id)
    scope = socket.assigns.current_scope

    case parse_action(kind, scope, ingredient, params) do
      {:ok, _movement} ->
        {:noreply,
         socket
         |> assign(:action_target, nil)
         |> assign(:action_form, nil)
         |> put_flash(:info, gettext("Saved."))
         |> reload()}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, changeset} ->
        {:noreply,
         assign(socket, :action_form, to_form(changeset, action: :validate, as: :action))}
    end
  end

  @impl true
  def handle_info({:low_stock, _ingredient}, socket), do: {:noreply, reload(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Helpers

  defp do_save_ingredient(socket, attrs) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.ingredient_form_mode do
        :new -> Inventory.create_ingredient(scope, attrs)
        {:edit, id} -> Inventory.update_ingredient(scope, find_ingredient(socket, id), attrs)
      end

    case result do
      {:ok, _ingredient} ->
        {:noreply,
         socket
         |> reload()
         |> assign(
           :ingredient_form,
           to_form(Ingredient.creation_changeset(%Ingredient{}, %{}), as: :ingredient)
         )
         |> assign(:ingredient_form_mode, :new)
         |> put_flash(:info, gettext("Ingredient saved."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :ingredient_form, to_form(changeset, as: :ingredient))}
    end
  end

  defp parse_action(:restock, scope, ingredient, params) do
    with {:ok, qty} <- require_positive_qty(ingredient.unit, params["qty_input"]),
         {:ok, cost} <- parse_restock_cost(params["cost_amount"], scope.venue.currency) do
      Inventory.restock(scope, ingredient, qty, cost, scope.user && scope.user.id)
    end
  end

  defp parse_action(:adjust, scope, ingredient, params) do
    case UnitInput.parse(ingredient.unit, params["qty_input"] || "") do
      {:ok, qty} ->
        Inventory.adjust_stock(
          scope,
          ingredient,
          qty,
          params["note"],
          scope.user && scope.user.id
        )

      :error ->
        {:error, gettext("Enter a valid quantity, e.g. 1.5kg or -200g.")}
    end
  end

  defp parse_action(:wastage, scope, ingredient, params) do
    with {:ok, qty} <- require_positive_qty(ingredient.unit, params["qty_input"]) do
      Inventory.log_wastage(scope, ingredient, qty, params["note"], scope.user && scope.user.id)
    end
  end

  # Bridges `parse_cost/2`'s field-tagged error (for the main ingredient
  # form's per-field messages) to the plain-message shape `save_action`
  # expects — and, unlike the ingredient form's optional cost, a restock
  # without the price paid is exactly the one thing this action can't
  # skip (build-plan.md Feature 13 "restock entry records unit_cost paid").
  defp parse_restock_cost(amount_str, currency) do
    case parse_cost(amount_str, currency) do
      {:ok, nil} -> {:error, gettext("Enter the price paid per unit.")}
      {:ok, cost} -> {:ok, cost}
      {:error, _field, message} -> {:error, message}
    end
  end

  defp require_positive_qty(unit, input) do
    case UnitInput.parse(unit, input || "") do
      {:ok, qty} ->
        if Decimal.positive?(qty),
          do: {:ok, qty},
          else: {:error, gettext("Enter a quantity greater than zero.")}

      :error ->
        {:error, gettext("Enter a valid quantity, e.g. 1.5kg or 500g.")}
    end
  end

  defp unit_from_params(_socket, %{"unit" => unit}) when unit in ["g", "ml", "piece"],
    do: String.to_existing_atom(unit)

  defp unit_from_params(socket, _params) do
    case socket.assigns.ingredient_form_mode do
      {:edit, id} -> find_ingredient(socket, id).unit
      :new -> :g
    end
  end

  defp parse_threshold(_unit, nil), do: {:ok, nil}
  defp parse_threshold(_unit, ""), do: {:ok, nil}

  defp parse_threshold(unit, input) do
    case UnitInput.parse(unit, input) do
      {:ok, qty} -> {:ok, qty}
      :error -> {:error, :min_threshold, gettext("must be a valid quantity, e.g. 1.5kg")}
    end
  end

  defp parse_cost(nil, _currency), do: {:ok, nil}
  defp parse_cost("", _currency), do: {:ok, nil}

  defp parse_cost(amount_str, currency) do
    case Decimal.parse(amount_str) do
      {decimal, ""} -> {:ok, Money.new!(currency, decimal)}
      _ -> {:error, :cost_per_unit, gettext("must be a valid amount")}
    end
  end

  defp threshold_input(%Ingredient{min_threshold: nil}), do: nil
  defp threshold_input(%Ingredient{min_threshold: threshold}), do: Decimal.to_string(threshold)

  defp cost_input(%Ingredient{cost_per_unit: nil}), do: nil

  defp cost_input(%Ingredient{cost_per_unit: cost}),
    do: cost |> Money.to_decimal() |> Decimal.to_string()

  defp ingredient_changeset(socket, params) do
    case socket.assigns.ingredient_form_mode do
      {:edit, id} -> Ingredient.update_changeset(find_ingredient(socket, id), params)
      :new -> Ingredient.creation_changeset(%Ingredient{}, params)
    end
  end

  defp find_ingredient(socket, id), do: Enum.find(socket.assigns.ingredients, &(&1.id == id))

  defp reload(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:ingredients, Inventory.list_ingredients(scope))
    |> assign(:low_stock, Inventory.list_low_stock(scope))
    |> assign(:negative_stock, Inventory.list_negative_stock(scope))
  end
end

defmodule TabletapWeb.Manager.IngredientsLive do
  @moduledoc """
  Manager-facing ingredient library (build-plan.md Feature 12):
  create/edit/archive ingredients with base units, thresholds, and
  cost-per-unit. Recipe attachment lives on
  `TabletapWeb.Manager.MenuLive`'s item modal, same split
  `Manager.ModifiersLive`/`Manager.MenuLive` already use for modifier
  groups (reusable library here, per-item attachment there).
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
      </div>
      <p class="text-sm text-base-content/60 mb-6 max-w-prose">
        {gettext(
          "Ingredients, stock levels, and thresholds. Attach a recipe to a menu item from the menu editor."
        )}
      </p>

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
          class="rounded-box bg-base-100 shadow-sm p-4"
        >
          <div class="flex items-center justify-between gap-3 flex-wrap">
            <div class="flex items-center gap-2 flex-wrap min-w-0">
              <span class="font-semibold">{ingredient.name}</span>
              <span class="badge badge-ghost badge-sm">
                {Decimal.to_string(ingredient.stock_qty)} {ingredient.unit}
              </span>
            </div>
            <div class="flex items-center gap-2">
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
        </div>

        <p :if={@ingredients == []} class="text-sm text-base-content/50">
          {gettext("No ingredients yet — add one above to get started.")}
        </p>
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
     |> assign(
       :ingredient_form,
       to_form(Ingredient.creation_changeset(%Ingredient{}, %{}), as: :ingredient)
     )
     |> assign(:ingredient_form_mode, :new)
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
    assign(socket, :ingredients, Inventory.list_ingredients(scope))
  end
end

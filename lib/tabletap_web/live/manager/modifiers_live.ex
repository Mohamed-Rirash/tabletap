defmodule TabletapWeb.Manager.ModifiersLive do
  @moduledoc """
  Manager-facing modifier-group library (build-plan.md Feature 05):
  groups with min/max/required selection rules and their options with
  price deltas. Groups are venue-level and reusable — attaching them to
  items happens in `TabletapWeb.Manager.MenuLive`'s item modal, which
  also shows the resulting computed price range.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Catalog
  alias Tabletap.Catalog.{ModifierGroup, ModifierOption}
  alias Tabletap.{Inventory, Tenants}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:modifiers}
      venues={@venues}
    >
      <div class="flex items-center justify-between flex-wrap gap-4 mb-2">
        <h1 class="text-2xl font-bold">{gettext("Modifiers")}</h1>
      </div>
      <p class="text-sm text-base-content/60 mb-6 max-w-prose">
        {gettext(
          "Reusable option groups — sizes, extras, removals. Build a group once, then attach it to any item from the menu editor."
        )}
      </p>

      <form
        id="group-form"
        phx-submit="save_group"
        phx-change="validate_group"
        class="mb-8 rounded-box bg-base-100 shadow-sm p-5"
      >
        <h2 class="font-semibold mb-3">
          {if @group_form_mode == :new, do: gettext("New group"), else: gettext("Edit group")}
        </h2>
        <div class="grid gap-3 sm:grid-cols-4 items-end">
          <.input
            field={@group_form[:name]}
            type="text"
            label={gettext("Name")}
            placeholder={gettext("e.g. Extras")}
          />
          <.input field={@group_form[:min_selections]} type="number" label={gettext("Min picks")} />
          <.input field={@group_form[:max_selections]} type="number" label={gettext("Max picks")} />
          <.input field={@group_form[:required]} type="checkbox" label={gettext("Required")} />
        </div>
        <div class="flex gap-2 mt-3">
          <button type="submit" class="btn btn-primary btn-sm">
            {if @group_form_mode == :new, do: gettext("Add group"), else: gettext("Save changes")}
          </button>
          <button
            :if={@group_form_mode != :new}
            type="button"
            phx-click="cancel_group_edit"
            class="btn btn-ghost btn-sm"
          >
            {gettext("Cancel")}
          </button>
        </div>
      </form>

      <div class="space-y-6">
        <div
          :for={group <- @groups}
          id={"modifier-group-#{group.id}"}
          class="rounded-box bg-base-100 shadow-sm p-5"
        >
          <div class="flex items-center justify-between gap-3 flex-wrap">
            <div class="flex items-center gap-2 flex-wrap">
              <h2 class="font-semibold text-lg">{group.name}</h2>
              <span class="badge badge-ghost badge-sm">{rules_label(group)}</span>
              <span :if={group.required} class="badge badge-primary badge-soft badge-sm">
                {gettext("Required")}
              </span>
            </div>

            <div class="flex items-center gap-2">
              <button
                type="button"
                phx-click="edit_group"
                phx-value-id={group.id}
                class="btn btn-xs btn-ghost"
              >
                {gettext("Edit")}
              </button>
              <button
                type="button"
                phx-click="archive_group"
                phx-value-id={group.id}
                data-confirm={
                  gettext("Archive this group? It'll be detached from every item and hidden.")
                }
                class="btn btn-xs btn-ghost text-error"
              >
                {gettext("Archive")}
              </button>
            </div>
          </div>

          <div class="mt-4 divide-y divide-base-300">
            <div
              :for={option <- group.options}
              id={"modifier-option-#{option.id}"}
              class="py-2 flex items-center justify-between gap-3 flex-wrap"
            >
              <div class="flex items-center gap-2 flex-wrap">
                <span class="font-medium">{option.name}</span>
                <span :if={option.default} class="badge badge-ghost badge-xs">
                  {gettext("Pre-selected")}
                </span>
                <span :if={!option.active} class="badge badge-warning badge-xs">
                  {gettext("Inactive")}
                </span>
              </div>

              <div class="flex items-center gap-2">
                <span class="font-semibold tabular-nums whitespace-nowrap">
                  {delta_sign(option.price_delta)}<.money amount={option.price_delta} />
                </span>
                <button
                  type="button"
                  phx-click="toggle_option_active"
                  phx-value-id={option.id}
                  class="btn btn-xs btn-outline"
                >
                  {if option.active, do: gettext("Deactivate"), else: gettext("Activate")}
                </button>
                <button
                  type="button"
                  phx-click="open_option_form"
                  phx-value-option-id={option.id}
                  class="btn btn-xs btn-ghost"
                >
                  {gettext("Edit")}
                </button>
                <button
                  type="button"
                  phx-click="archive_option"
                  phx-value-id={option.id}
                  data-confirm={gettext("Archive this option?")}
                  class="btn btn-xs btn-ghost text-error"
                >
                  {gettext("Archive")}
                </button>
              </div>
            </div>

            <p :if={group.options == []} class="py-3 text-sm text-base-content/50">
              {gettext("No options yet.")}
            </p>
          </div>

          <form
            :if={option_form_for_group?(@option_form_target, group)}
            id={"option-form-#{group.id}"}
            phx-submit="save_option"
            phx-change="validate_option"
            class="mt-3 rounded-field bg-base-200/60 p-3"
          >
            <div class="grid gap-3 sm:grid-cols-3 items-end">
              <.input
                field={@option_form[:name]}
                type="text"
                label={gettext("Option name")}
                placeholder={gettext("e.g. Extra cheese")}
              />
              <div class="fieldset mb-2">
                <label for={"option-price-delta-#{group.id}"}>
                  <span class="label mb-1">{gettext("Price change")}</span>
                  <input
                    type="text"
                    id={"option-price-delta-#{group.id}"}
                    name="option[price_delta_amount]"
                    value={@option_form.params["price_delta_amount"]}
                    inputmode="decimal"
                    placeholder="0.00"
                    class="w-full input"
                  />
                  <p
                    :for={msg <- translate_errors(@option_form.source.errors, :price_delta)}
                    class="mt-1.5 flex gap-2 items-center text-sm text-error"
                  >
                    <.icon name="hero-exclamation-circle" class="size-5" /> {msg}
                  </p>
                </label>
              </div>
              <.input
                field={@option_form[:default]}
                type="checkbox"
                label={gettext("Pre-selected")}
              />
            </div>
            <div class="grid gap-3 sm:grid-cols-3 items-end mt-3">
              <div class="fieldset mb-2">
                <label for={"option-ingredient-#{group.id}"}>
                  <span class="label mb-1">{gettext("Stock effect (optional)")}</span>
                  <select
                    id={"option-ingredient-#{group.id}"}
                    name="option[ingredient_id]"
                    class="w-full select select-sm"
                  >
                    <option value="">{gettext("No stock effect")}</option>
                    <option
                      :for={ingredient <- @ingredients}
                      value={ingredient.id}
                      selected={ingredient.id == @option_form.params["ingredient_id"]}
                    >
                      {ingredient.name} ({ingredient.unit})
                    </option>
                  </select>
                </label>
              </div>
              <div class="fieldset mb-2">
                <label for={"option-ingredient-delta-#{group.id}"}>
                  <span class="label mb-1">{gettext("Quantity delta")}</span>
                  <input
                    type="text"
                    id={"option-ingredient-delta-#{group.id}"}
                    name="option[ingredient_qty_delta_input]"
                    value={@option_form.params["ingredient_qty_delta_input"]}
                    placeholder={gettext("e.g. 20g or -15g")}
                    class="w-full input input-sm"
                  />
                  <p
                    :for={msg <- translate_errors(@option_form.source.errors, :ingredient_qty_delta)}
                    class="mt-1.5 flex gap-2 items-center text-sm text-error"
                  >
                    <.icon name="hero-exclamation-circle" class="size-5" /> {msg}
                  </p>
                </label>
              </div>
            </div>
            <div class="flex gap-2 mt-2">
              <button type="submit" class="btn btn-sm btn-primary">
                {if match?({:edit, _}, @option_form_target),
                  do: gettext("Save option"),
                  else: gettext("Add option")}
              </button>
              <button type="button" phx-click="cancel_option_form" class="btn btn-sm btn-ghost">
                {gettext("Cancel")}
              </button>
            </div>
          </form>

          <button
            :if={!option_form_for_group?(@option_form_target, group)}
            type="button"
            phx-click="open_option_form"
            phx-value-group-id={group.id}
            class="btn btn-sm btn-outline mt-3"
          >
            {gettext("Add option")}
          </button>
        </div>

        <p :if={@groups == []} class="text-sm text-base-content/50">
          {gettext("No modifier groups yet — add one above to get started.")}
        </p>
      </div>
    </Layouts.manager>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:venues, Tenants.list_venues(socket.assigns.current_scope))
     |> assign(:group_form, to_form(ModifierGroup.creation_changeset(%ModifierGroup{}, %{})))
     |> assign(:group_form_mode, :new)
     |> assign(:option_form, nil)
     |> assign(:option_form_target, nil)
     |> assign(:ingredients, Inventory.list_ingredients(socket.assigns.current_scope))
     |> reload_groups()}
  end

  ## Groups

  @impl true
  def handle_event("validate_group", %{"modifier_group" => params}, socket) do
    changeset = socket |> group_changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :group_form, to_form(changeset))}
  end

  def handle_event("save_group", %{"modifier_group" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.group_form_mode do
        :new -> Catalog.create_modifier_group(scope, params)
        {:edit, id} -> Catalog.update_modifier_group(scope, find_group(socket, id), params)
      end

    case result do
      {:ok, _group} ->
        {:noreply,
         socket
         |> reload_groups()
         |> assign(:group_form, to_form(ModifierGroup.creation_changeset(%ModifierGroup{}, %{})))
         |> assign(:group_form_mode, :new)
         |> put_flash(:info, gettext("Group saved."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :group_form, to_form(changeset))}
    end
  end

  def handle_event("edit_group", %{"id" => id}, socket) do
    group = find_group(socket, id)

    {:noreply,
     socket
     |> assign(:group_form, to_form(ModifierGroup.update_changeset(group, %{})))
     |> assign(:group_form_mode, {:edit, id})}
  end

  def handle_event("cancel_group_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:group_form, to_form(ModifierGroup.creation_changeset(%ModifierGroup{}, %{})))
     |> assign(:group_form_mode, :new)}
  end

  def handle_event("archive_group", %{"id" => id}, socket) do
    {:ok, _} =
      Catalog.archive_modifier_group(socket.assigns.current_scope, find_group(socket, id))

    {:noreply, reload_groups(socket)}
  end

  ## Options

  def handle_event("open_option_form", %{"group-id" => group_id}, socket) do
    changeset = ModifierOption.creation_changeset(%ModifierOption{}, %{})

    {:noreply,
     socket
     |> assign(:option_form, to_form(changeset, as: :option))
     |> assign(:option_form_target, {:new, group_id})}
  end

  def handle_event("open_option_form", %{"option-id" => option_id}, socket) do
    option = find_option(socket, option_id)

    changeset =
      ModifierOption.update_changeset(option, %{
        "price_delta_amount" => option.price_delta |> Money.to_decimal() |> Decimal.to_string(),
        "ingredient_id" => option.ingredient_id,
        "ingredient_qty_delta_input" =>
          option.ingredient_qty_delta && Decimal.to_string(option.ingredient_qty_delta)
      })

    {:noreply,
     socket
     |> assign(:option_form, to_form(changeset, as: :option))
     |> assign(:option_form_target, {:edit, option})}
  end

  def handle_event("cancel_option_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:option_form, nil)
     |> assign(:option_form_target, nil)}
  end

  def handle_event("validate_option", %{"option" => params}, socket) do
    changeset = socket |> option_changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :option_form, to_form(changeset, as: :option))}
  end

  def handle_event("save_option", %{"option" => params}, socket) do
    venue = socket.assigns.current_scope.venue

    with {:ok, delta} <- price_delta_or_error(params["price_delta_amount"], venue.currency),
         {:ok, ingredient_attrs} <- parse_ingredient_delta(socket, params) do
      attrs = params |> Map.put("price_delta", delta) |> Map.merge(ingredient_attrs)
      do_save_option(socket, attrs)
    else
      {:error, field, message} ->
        changeset =
          socket
          |> option_changeset(params)
          |> Ecto.Changeset.add_error(field, message)
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :option_form, to_form(changeset, as: :option))}
    end
  end

  def handle_event("toggle_option_active", %{"id" => id}, socket) do
    option = find_option(socket, id)

    {:ok, _} =
      Catalog.update_modifier_option(socket.assigns.current_scope, option, %{
        "active" => !option.active
      })

    {:noreply, reload_groups(socket)}
  end

  def handle_event("archive_option", %{"id" => id}, socket) do
    {:ok, _} =
      Catalog.archive_modifier_option(socket.assigns.current_scope, find_option(socket, id))

    {:noreply, reload_groups(socket)}
  end

  ## Helpers

  defp price_delta_or_error(amount_str, currency) do
    case parse_delta(amount_str, currency) do
      {:ok, delta} -> {:ok, delta}
      :error -> {:error, :price_delta, gettext("must be a valid amount")}
    end
  end

  # "" (nothing picked) is the common case — no stock effect at all,
  # same as leaving both database columns nil.
  defp parse_ingredient_delta(_socket, %{"ingredient_id" => ""}),
    do: {:ok, %{"ingredient_id" => nil, "ingredient_qty_delta" => nil}}

  defp parse_ingredient_delta(socket, %{"ingredient_id" => ingredient_id} = params) do
    scope = socket.assigns.current_scope
    ingredient = Inventory.get_ingredient(scope, ingredient_id)

    case Inventory.UnitInput.parse(ingredient.unit, params["ingredient_qty_delta_input"] || "") do
      {:ok, delta} ->
        {:ok, %{"ingredient_id" => ingredient_id, "ingredient_qty_delta" => delta}}

      :error ->
        {:error, :ingredient_qty_delta, gettext("must be a valid quantity, e.g. 20g or -15g")}
    end
  end

  defp do_save_option(socket, attrs) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.option_form_target do
        {:new, group_id} ->
          Catalog.create_modifier_option(scope, find_group(socket, group_id), attrs)

        {:edit, option} ->
          Catalog.update_modifier_option(scope, option, attrs)
      end

    case result do
      {:ok, _option} ->
        {:noreply,
         socket
         |> reload_groups()
         |> assign(:option_form, nil)
         |> assign(:option_form_target, nil)
         |> put_flash(:info, gettext("Option saved."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :option_form, to_form(changeset, as: :option))}
    end
  end

  defp group_changeset(socket, params) do
    case socket.assigns.group_form_mode do
      {:edit, id} -> ModifierGroup.update_changeset(find_group(socket, id), params)
      :new -> ModifierGroup.creation_changeset(%ModifierGroup{}, params)
    end
  end

  defp option_changeset(socket, params) do
    case socket.assigns.option_form_target do
      {:edit, option} -> ModifierOption.update_changeset(option, params)
      {:new, _group_id} -> ModifierOption.creation_changeset(%ModifierOption{}, params)
    end
  end

  defp find_group(socket, id), do: Enum.find(socket.assigns.groups, &(&1.id == id))

  defp find_option(socket, id) do
    socket.assigns.groups
    |> Enum.flat_map(& &1.options)
    |> Enum.find(&(&1.id == id))
  end

  defp option_form_for_group?({:new, group_id}, group), do: group_id == group.id
  defp option_form_for_group?({:edit, option}, group), do: option.group_id == group.id
  defp option_form_for_group?(nil, _group), do: false

  defp rules_label(%ModifierGroup{min_selections: same, max_selections: same}),
    do: gettext("Pick %{count}", count: same)

  defp rules_label(group),
    do: gettext("Pick %{min}–%{max}", min: group.min_selections, max: group.max_selections)

  # `<.money>` renders the sign for negative deltas; surcharges get an
  # explicit plus so "+$1.00" reads as a delta, not a price.
  defp delta_sign(%Money{} = delta) do
    if Money.compare!(delta, Money.new!(delta.currency, 0)) == :gt, do: "+", else: ""
  end

  defp parse_delta(nil, _currency), do: :error

  defp parse_delta(amount_str, currency) do
    case Decimal.parse(amount_str) do
      {decimal, ""} -> {:ok, Money.new!(currency, decimal)}
      _ -> :error
    end
  end

  defp reload_groups(socket) do
    assign(socket, :groups, Catalog.list_modifier_groups(socket.assigns.current_scope))
  end
end

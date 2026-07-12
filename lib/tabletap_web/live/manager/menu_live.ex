defmodule TabletapWeb.Manager.MenuLive do
  @moduledoc """
  Manager-facing menu builder (build-plan.md Feature 04): categories,
  items, photo upload, drag-to-reorder, archive-not-delete, the
  `active`/`available_today` toggles, and daily limits. Every mutation
  broadcasts on `"venue:<id>:menu"` so `TabletapWeb.Public.MenuLive`
  updates instantly — the build-plan verify step ("toggling availability
  hides the item from the public menu instantly").
  """
  use TabletapWeb, :live_view

  alias Tabletap.Catalog
  alias Tabletap.Catalog.{Category, DailyItemLimit, MenuItem}
  alias Tabletap.{Storage, Tenants}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager flash={@flash} current_scope={@current_scope} active_nav={:menu} venues={@venues}>
      <div class="flex items-center justify-between flex-wrap gap-4 mb-4">
        <h1 class="text-2xl font-bold">{gettext("Menu")}</h1>
        <a
          href={~p"/venues/#{@current_scope.venue.slug}/menu"}
          target="_blank"
          class="btn btn-sm btn-outline"
        >
          {gettext("View public menu")}
        </a>
      </div>

      <div role="tablist" class="tabs tabs-border mb-6">
        <button
          type="button"
          role="tab"
          phx-click="switch_tab"
          phx-value-tab="editing"
          class={["tab", @tab == :editing && "tab-active"]}
        >
          {gettext("Menu Editing")}
        </button>
        <button
          type="button"
          role="tab"
          phx-click="switch_tab"
          phx-value-tab="preview"
          class={["tab", @tab == :preview && "tab-active"]}
        >
          {gettext("Preview")}
        </button>
      </div>

      <% out_of_stock = out_of_stock_count(@menu, @daily_limits) %>
      <div class="mb-6 space-y-4">
        <div class="flex items-center gap-4 flex-wrap">
          <form id="menu-search-form" phx-change="search" class="flex-1 max-w-md">
            <label class="input w-full rounded-full bg-base-100">
              <.icon name="hero-magnifying-glass" class="size-4 opacity-50" />
              <input
                type="text"
                name="search"
                value={@search}
                placeholder={gettext("Search category or menu...")}
                phx-debounce="300"
              />
            </label>
          </form>
          <span :if={out_of_stock > 0} class="text-sm font-semibold text-primary">
            {ngettext("%{count} item out of stock", "%{count} items out of stock", out_of_stock,
              count: out_of_stock
            )}
          </span>
        </div>

        <div class="flex gap-2 flex-wrap">
          <button
            type="button"
            phx-click="filter_category"
            phx-value-id=""
            class={[
              "btn btn-sm rounded-full border",
              @filter_category_id == nil && "btn-soft btn-primary border-primary/20",
              @filter_category_id != nil && "bg-base-100 border-base-300 font-medium"
            ]}
          >
            {gettext("All")}
          </button>
          <button
            :for={{category, _items} <- @menu}
            type="button"
            phx-click="filter_category"
            phx-value-id={category.id}
            class={[
              "btn btn-sm rounded-full border",
              @filter_category_id == category.id && "btn-soft btn-primary border-primary/20",
              @filter_category_id != category.id && "bg-base-100 border-base-300 font-medium"
            ]}
          >
            {category.name}
          </button>
        </div>
      </div>

      <% filtered = filtered_menu(@menu, @search, @filter_category_id) %>

      <div :if={@tab == :preview}>
        <.preview_grid menu={filtered} daily_limits={@daily_limits} />
      </div>

      <div :if={@tab == :editing}>
        <form
          id="category-form"
          phx-submit="save_category"
          phx-change="validate_category"
          class="mb-8 flex items-end gap-3"
        >
          <.input
            field={@category_form[:name]}
            type="text"
            label={
              if @category_form_mode == :new,
                do: gettext("New category name"),
                else: gettext("Category name")
            }
            placeholder={gettext("e.g. Drinks")}
          />
          <button type="submit" class="btn btn-primary mb-2">
            {if @category_form_mode == :new, do: gettext("Add category"), else: gettext("Save")}
          </button>
          <button
            :if={@category_form_mode != :new}
            type="button"
            phx-click="cancel_category_edit"
            class="btn btn-ghost mb-2"
          >
            {gettext("Cancel")}
          </button>
        </form>

        <% unfiltered? = @search == "" && is_nil(@filter_category_id) %>
        <div
          id="categories"
          phx-hook={unfiltered? && ".Reorder"}
          data-scope="categories"
          class="space-y-6"
        >
          <div
            :for={{category, items} <- filtered}
            id={"category-#{category.id}"}
            data-id={category.id}
            draggable="true"
            class="rounded-box bg-base-100 shadow-sm p-5"
          >
            <div class="flex items-center justify-between gap-3 flex-wrap">
              <div class="flex items-center gap-2 cursor-grab" title={gettext("Drag to reorder")}>
                <.icon name="hero-bars-2" class="size-4 opacity-40" />
                <h2 class="font-semibold text-lg">{category.name}</h2>
                <span :if={!category.active} class="badge badge-ghost badge-sm">
                  {gettext("Inactive")}
                </span>
              </div>

              <div class="flex items-center gap-2">
                <button
                  type="button"
                  phx-click="toggle_category_active"
                  phx-value-id={category.id}
                  class="btn btn-xs btn-outline"
                >
                  {if category.active, do: gettext("Deactivate"), else: gettext("Activate")}
                </button>
                <button
                  type="button"
                  phx-click="edit_category"
                  phx-value-id={category.id}
                  class="btn btn-xs btn-ghost"
                >
                  {gettext("Rename")}
                </button>
                <button
                  type="button"
                  phx-click="archive_category"
                  phx-value-id={category.id}
                  data-confirm={
                    gettext("Archive this category? It'll be hidden from menus and pickers.")
                  }
                  class="btn btn-xs btn-ghost text-error"
                >
                  {gettext("Archive")}
                </button>
              </div>
            </div>

            <div
              id={"items-#{category.id}"}
              phx-hook={unfiltered? && ".Reorder"}
              data-scope="items"
              data-category-id={category.id}
              class="mt-4 divide-y divide-base-300"
            >
              <.item_row
                :for={item <- items}
                item={item}
                daily_limit={Map.get(@daily_limits, item.id)}
              />
              <p :if={items == [] && @search == ""} class="py-4 text-sm text-base-content/50">
                {gettext("No items yet.")}
              </p>
              <p :if={items == [] && @search != ""} class="py-4 text-sm text-base-content/50">
                {gettext("No items match \"%{search}\".", search: @search)}
              </p>
            </div>

            <button
              type="button"
              phx-click="open_item_form"
              phx-value-category-id={category.id}
              class="btn btn-sm btn-outline mt-4"
            >
              {gettext("Add item")}
            </button>
          </div>

          <p :if={filtered == []} class="text-sm text-base-content/50">
            {gettext("No categories yet — add one above to get started.")}
          </p>
        </div>
      </div>

      <% modal_item = match?({:edit, _}, @item_form_target) && elem(@item_form_target, 1) %>
      <.item_edit_modal
        :if={@item_form_target}
        form={@item_form}
        uploads={@uploads}
        categories={Enum.map(@menu, fn {c, _} -> c end)}
        mode={elem(@item_form_target, 0)}
        item={modal_item || nil}
        daily_limit={modal_item && Map.get(@daily_limits, modal_item.id)}
      />

      <% preview_item = @preview_item_id && find_item_in_menu(@menu, @preview_item_id) %>
      <.item_preview_modal :if={preview_item} item={preview_item} />

      <script :type={Phoenix.LiveView.ColocatedHook} name=".Reorder">
        export default {
          mounted() {
            this.draggingId = null

            this.el.addEventListener("dragstart", (e) => {
              const row = e.target.closest("[data-id]")
              if (!row || row.parentNode !== this.el) return
              this.draggingId = row.dataset.id
              row.classList.add("opacity-40")
              e.dataTransfer.effectAllowed = "move"
            })

            this.el.addEventListener("dragend", (e) => {
              const row = e.target.closest("[data-id]")
              if (row) row.classList.remove("opacity-40")
              this.draggingId = null
            })

            this.el.addEventListener("dragover", (e) => {
              if (!this.draggingId) return
              e.preventDefault()
              const dragging = this.el.querySelector(`[data-id="${this.draggingId}"]`)
              const target = e.target.closest("[data-id]")
              if (!target || target === dragging || target.parentNode !== this.el) return
              const rect = target.getBoundingClientRect()
              const before = (e.clientY - rect.top) < rect.height / 2
              this.el.insertBefore(dragging, before ? target : target.nextSibling)
            })

            this.el.addEventListener("drop", (e) => {
              if (!this.draggingId) return
              e.preventDefault()
              const ids = Array.from(this.el.children)
                .filter((el) => el.dataset && el.dataset.id)
                .map((el) => el.dataset.id)
              this.pushEvent("reorder", {
                ids: ids,
                scope: this.el.dataset.scope,
                category_id: this.el.dataset.categoryId
              })
            })
          }
        }
      </script>
    </Layouts.manager>
    """
  end

  attr :menu, :list, required: true
  attr :daily_limits, :map, required: true

  defp preview_grid(assigns) do
    ~H"""
    <div :for={{category, items} <- @menu} :if={items != []} class="mb-10">
      <div class="flex items-baseline justify-between gap-3 mb-4">
        <h2 class="font-bold text-lg">{gettext("Choose %{category}", category: category.name)}</h2>
        <span class="text-sm text-base-content/50">
          {ngettext("%{count} Result", "%{count} Results", length(items), count: length(items))}
        </span>
      </div>

      <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
        <div
          :for={item <- items}
          phx-click="preview_item"
          phx-value-id={item.id}
          class="rounded-box bg-base-100 shadow-sm hover:shadow-md cursor-pointer transition-shadow p-4 text-center"
        >
          <div class="relative mx-auto size-28 sm:size-32">
            <img
              :if={item.photo_url}
              src={item.photo_url}
              class="size-full rounded-full object-cover"
            />
            <div
              :if={!item.photo_url}
              class="size-full rounded-full bg-base-200 grid place-items-center"
            >
              <.icon name="hero-photo" class="size-8 opacity-30" />
            </div>
            <span
              :if={!item.available_today}
              class="absolute inset-0 grid place-items-center rounded-full bg-base-100/80 text-sm font-semibold"
            >
              {gettext("Off today")}
            </span>
          </div>

          <p class="font-semibold mt-3 truncate">{item.name}</p>
          <p
            :if={item.ingredients}
            class="text-xs text-base-content/50 truncate mt-0.5"
            title={item.ingredients}
          >
            {item.ingredients}
          </p>
          <p class="font-bold text-primary mt-1"><.money amount={item.price} /></p>
          <p class="text-xs text-base-content/50 mt-1">
            {availability_label(item, Map.get(@daily_limits, item.id))}
          </p>
        </div>
      </div>
    </div>

    <p :if={Enum.all?(@menu, fn {_c, items} -> items == [] end)} class="text-sm text-base-content/50">
      {gettext("No items to preview yet — add some in Menu Editing.")}
    </p>
    """
  end

  attr :item, MenuItem, required: true

  defp item_preview_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50">
      <div class="absolute inset-0 bg-black/40" phx-click="close_preview_item"></div>
      <div class="absolute inset-0 flex items-center justify-center p-4 pointer-events-none">
        <div class="pointer-events-auto bg-base-100 rounded-box max-w-lg w-full max-h-[90vh] overflow-y-auto shadow-xl">
          <div class="relative aspect-video bg-base-200">
            <img :if={@item.photo_url} src={@item.photo_url} class="h-full w-full object-cover" />
            <div :if={!@item.photo_url} class="h-full w-full grid place-items-center">
              <.icon name="hero-photo" class="size-10 opacity-30" />
            </div>
            <button
              type="button"
              phx-click="close_preview_item"
              class="btn btn-circle btn-sm absolute top-3 right-3 bg-base-100/90"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <div class="p-5">
            <div class="flex items-start justify-between gap-3">
              <h3 class="text-xl font-bold">{@item.name}</h3>
              <.money amount={@item.price} class="text-lg font-bold whitespace-nowrap" />
            </div>

            <div class="flex gap-1 mt-2 flex-wrap">
              <span :if={!@item.available_today} class="badge badge-warning badge-sm">
                {gettext("Off today")}
              </span>
              <span :for={tag <- @item.dietary_tags} class="badge badge-outline badge-sm">{tag}</span>
              <span
                :for={tag <- @item.allergen_tags}
                class="badge badge-outline badge-sm text-warning"
              >
                {tag}
              </span>
            </div>

            <p :if={@item.description} class="mt-3 text-base-content/70">{@item.description}</p>

            <div :if={@item.ingredients} class="mt-4">
              <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50 mb-1">
                {gettext("Ingredients")}
              </p>
              <p class="text-sm">{@item.ingredients}</p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :item, MenuItem, required: true
  attr :daily_limit, DailyItemLimit, default: nil

  defp item_row(assigns) do
    ~H"""
    <div id={"item-#{@item.id}"} data-id={@item.id} draggable="true" class="py-3">
      <div class="flex items-start gap-3">
        <.icon name="hero-bars-2" class="size-4 opacity-40 cursor-grab shrink-0 mt-1" />

        <img
          :if={@item.photo_url}
          src={@item.photo_url}
          class="size-12 rounded-field object-cover shrink-0"
        />
        <div
          :if={!@item.photo_url}
          class="size-12 rounded-field bg-base-200 grid place-items-center shrink-0"
        >
          <.icon name="hero-photo" class="size-5 opacity-40" />
        </div>

        <div class="flex-1 min-w-0">
          <div class="flex items-center justify-between gap-2 flex-wrap">
            <div class="flex items-center gap-2 flex-wrap">
              <span class="font-medium">{@item.name}</span>
              <span :if={!@item.active} class="badge badge-ghost badge-xs">
                {gettext("Inactive")}
              </span>
              <span :if={!@item.available_today} class="badge badge-warning badge-xs">
                {gettext("Off today")}
              </span>
            </div>
            <.money amount={@item.price} class="font-semibold whitespace-nowrap" />
          </div>
          <p :if={@item.description} class="text-sm text-base-content/60 truncate">
            {@item.description}
          </p>
          <div class="flex gap-1 mt-1 flex-wrap">
            <span :for={tag <- @item.dietary_tags} class="badge badge-outline badge-xs">{tag}</span>
            <span :for={tag <- @item.allergen_tags} class="badge badge-outline badge-xs text-warning">
              {tag}
            </span>
          </div>

          <div class="flex items-center gap-1 flex-wrap mt-2">
            <button
              type="button"
              phx-click="toggle_item_available"
              phx-value-id={@item.id}
              class="btn btn-xs btn-outline"
            >
              {if @item.available_today, do: gettext("Turn off today"), else: gettext("Turn on today")}
            </button>
            <button
              type="button"
              phx-click="open_item_form"
              phx-value-item-id={@item.id}
              class="btn btn-xs btn-ghost"
            >
              {gettext("Edit")}
            </button>
            <button
              type="button"
              phx-click="archive_item"
              phx-value-id={@item.id}
              data-confirm={gettext("Archive this item?")}
              class="btn btn-xs btn-ghost text-error"
            >
              {gettext("Archive")}
            </button>
          </div>
        </div>
      </div>

      <form
        id={"daily-limit-form-#{@item.id}"}
        phx-submit="save_daily_limit"
        phx-value-item-id={@item.id}
        class="mt-1 ml-8 flex items-center gap-2 text-xs text-base-content/60"
      >
        <span :if={@daily_limit}>
          {gettext("%{remaining} of %{limit} left today",
            remaining: DailyItemLimit.remaining(@daily_limit),
            limit: @daily_limit.limit_qty
          )}
        </span>
        <span :if={!@daily_limit}>{gettext("No daily limit")}</span>
        <input
          type="number"
          name="limit_qty"
          min="1"
          value={@daily_limit && @daily_limit.limit_qty}
          placeholder={gettext("limit")}
          class="input input-xs w-16"
        />
        <button type="submit" class="btn btn-xs btn-ghost">{gettext("Set")}</button>
        <button
          :if={@daily_limit}
          type="button"
          phx-click="clear_daily_limit"
          phx-value-item-id={@item.id}
          class="btn btn-xs btn-ghost"
        >
          {gettext("Clear")}
        </button>
      </form>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :uploads, :map, required: true
  attr :categories, :list, required: true
  attr :mode, :atom, required: true
  attr :item, MenuItem, default: nil
  attr :daily_limit, DailyItemLimit, default: nil

  defp item_edit_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50">
      <div class="absolute inset-0 bg-black/40" phx-click="cancel_item_form"></div>
      <div class="absolute inset-0 flex items-center justify-center p-4 pointer-events-none">
        <div class="pointer-events-auto bg-base-100 rounded-box max-w-lg w-full max-h-[90vh] overflow-y-auto shadow-xl">
          <div class="relative aspect-video bg-base-200">
            <img
              :if={@item && @item.photo_url}
              src={@item.photo_url}
              class="h-full w-full object-cover"
            />
            <div :if={!(@item && @item.photo_url)} class="h-full w-full grid place-items-center">
              <.icon name="hero-photo" class="size-10 opacity-30" />
            </div>
            <button
              type="button"
              phx-click="cancel_item_form"
              class="btn btn-circle btn-sm absolute top-3 right-3 bg-base-100/90"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>

          <form
            id="item-form"
            phx-submit="save_item"
            phx-change="validate_item"
            phx-drop-target={@uploads.photo.ref}
            class="p-5 space-y-3"
          >
            <h3 class="text-lg font-semibold">
              {if @mode == :new, do: gettext("Add item"), else: gettext("Edit item")}
            </h3>

            <div class="grid gap-3 sm:grid-cols-2">
              <.input field={@form[:name]} type="text" label={gettext("Name")} />
              <div class="fieldset mb-2">
                <label for="item-price-amount">
                  <span class="label mb-1">{gettext("Price")}</span>
                  <input
                    type="text"
                    id="item-price-amount"
                    name="item[price_amount]"
                    value={@form.params["price_amount"]}
                    inputmode="decimal"
                    placeholder="0.00"
                    class="w-full input"
                  />
                  <p
                    :for={msg <- translate_errors(@form.source.errors, :price)}
                    class="mt-1.5 flex gap-2 items-center text-sm text-error"
                  >
                    <.icon name="hero-exclamation-circle" class="size-5" /> {msg}
                  </p>
                </label>
              </div>
            </div>

            <.input field={@form[:description]} type="textarea" label={gettext("Description")} />
            <.input
              field={@form[:ingredients]}
              type="textarea"
              label={gettext("Ingredients")}
              placeholder={gettext("Beef patty, brioche bun, cheddar, lettuce")}
            />

            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                field={@form[:prep_minutes]}
                type="number"
                label={gettext("Prep time (minutes)")}
              />
              <div class="fieldset mb-2">
                <label for="item-category-id">
                  <span class="label mb-1">{gettext("Category")}</span>
                  <select id="item-category-id" name="item[category_id]" class="w-full select">
                    <option
                      :for={c <- @categories}
                      value={c.id}
                      selected={c.id == @form.params["category_id"]}
                    >
                      {c.name}
                    </option>
                  </select>
                </label>
              </div>
            </div>

            <div>
              <span class="label mb-1">{gettext("Photo")}</span>
              <.live_file_input upload={@uploads.photo} class="file-input file-input-sm w-full" />
              <p :for={entry <- @uploads.photo.entries} class="text-xs text-base-content/60 mt-1">
                {entry.client_name} — {entry.progress}%
              </p>
              <p :for={{_ref, err} <- @uploads.photo.errors} class="text-xs text-error mt-1">
                {upload_error_to_string(err)}
              </p>
            </div>

            <div>
              <span class="label mb-1">{gettext("Dietary")}</span>
              <div class="flex flex-wrap gap-3">
                <input type="hidden" name="item[dietary_tags][]" value="" />
                <label :for={tag <- MenuItem.dietary_tag_options()} class="label gap-1.5 text-sm">
                  <input
                    type="checkbox"
                    name="item[dietary_tags][]"
                    value={tag}
                    checked={tag in (@form[:dietary_tags].value || [])}
                    class="checkbox checkbox-xs"
                  /> {tag}
                </label>
              </div>
            </div>

            <div>
              <span class="label mb-1">{gettext("Allergens")}</span>
              <div class="flex flex-wrap gap-3">
                <input type="hidden" name="item[allergen_tags][]" value="" />
                <label :for={tag <- MenuItem.allergen_tag_options()} class="label gap-1.5 text-sm">
                  <input
                    type="checkbox"
                    name="item[allergen_tags][]"
                    value={tag}
                    checked={tag in (@form[:allergen_tags].value || [])}
                    class="checkbox checkbox-xs"
                  /> {tag}
                </label>
              </div>
            </div>

            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-sm">
                {if @mode == :new, do: gettext("Add item"), else: gettext("Save changes")}
              </button>
              <button type="button" phx-click="cancel_item_form" class="btn btn-ghost btn-sm">
                {gettext("Cancel")}
              </button>
            </div>
          </form>

          <div :if={@item} class="border-t border-base-300 p-5">
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50 mb-2">
              {gettext("Quantity available today")}
            </p>
            <form
              id={"daily-limit-form-modal-#{@item.id}"}
              phx-submit="save_daily_limit"
              phx-value-item-id={@item.id}
              class="flex items-center gap-2 text-sm"
            >
              <span :if={@daily_limit} class="text-base-content/70">
                {gettext("%{remaining} of %{limit} left today",
                  remaining: DailyItemLimit.remaining(@daily_limit),
                  limit: @daily_limit.limit_qty
                )}
              </span>
              <span :if={!@daily_limit} class="text-base-content/70">
                {gettext("No daily limit — unlimited")}
              </span>
              <input
                type="number"
                name="limit_qty"
                min="1"
                value={@daily_limit && @daily_limit.limit_qty}
                placeholder={gettext("limit")}
                class="input input-sm w-20"
              />
              <button type="submit" class="btn btn-sm btn-outline">{gettext("Set")}</button>
              <button
                :if={@daily_limit}
                type="button"
                phx-click="clear_daily_limit"
                phx-value-item-id={@item.id}
                class="btn btn-sm btn-ghost"
              >
                {gettext("Clear")}
              </button>
            </form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:tab, :editing)
     |> assign(:search, "")
     |> assign(:filter_category_id, nil)
     |> assign(:preview_item_id, nil)
     |> assign(:venues, Tenants.list_venues(socket.assigns.current_scope))
     |> assign(:category_form, to_form(Category.creation_changeset(%Category{}, %{})))
     |> assign(:category_form_mode, :new)
     |> assign(:item_form, nil)
     |> assign(:item_form_target, nil)
     |> allow_upload(:photo,
       accept: ~w(.jpg .jpeg .png .webp),
       max_entries: 1,
       max_file_size: 6_000_000,
       external: &presign_entry/2
     )
     |> reload_menu()}
  end

  defp presign_entry(entry, socket) do
    scope = socket.assigns.current_scope

    key =
      Storage.menu_item_photo_key(scope.org.id, scope.venue.id, Path.extname(entry.client_name))

    {:ok, %{url: url, headers: headers}} = Storage.presigned_upload_url(key)
    {:ok, %{uploader: "S3", url: url, headers: headers, key: key}, socket}
  end

  ## Tabs

  @impl true
  def handle_event("switch_tab", %{"tab" => "editing"}, socket),
    do: {:noreply, assign(socket, :tab, :editing)}

  def handle_event("switch_tab", %{"tab" => "preview"}, socket),
    do: {:noreply, assign(socket, :tab, :preview)}

  ## Search / filter / preview-detail

  def handle_event("search", %{"search" => value}, socket),
    do: {:noreply, assign(socket, :search, value)}

  def handle_event("filter_category", %{"id" => ""}, socket),
    do: {:noreply, assign(socket, :filter_category_id, nil)}

  def handle_event("filter_category", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :filter_category_id, id)}

  def handle_event("preview_item", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :preview_item_id, id)}

  def handle_event("close_preview_item", _params, socket),
    do: {:noreply, assign(socket, :preview_item_id, nil)}

  ## Categories

  def handle_event("validate_category", %{"category" => params}, socket) do
    changeset = socket |> category_changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :category_form, to_form(changeset))}
  end

  def handle_event("save_category", %{"category" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.category_form_mode do
        :new -> Catalog.create_category(scope, params)
        {:edit, id} -> Catalog.update_category(scope, find_category(socket, id), params)
      end

    case result do
      {:ok, _category} ->
        {:noreply,
         socket
         |> reload_menu()
         |> broadcast_menu_updated()
         |> assign(:category_form, to_form(Category.creation_changeset(%Category{}, %{})))
         |> assign(:category_form_mode, :new)
         |> put_flash(:info, gettext("Category saved."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :category_form, to_form(changeset))}
    end
  end

  def handle_event("edit_category", %{"id" => id}, socket) do
    category = find_category(socket, id)

    {:noreply,
     socket
     |> assign(:category_form, to_form(Category.update_changeset(category, %{})))
     |> assign(:category_form_mode, {:edit, id})}
  end

  def handle_event("cancel_category_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:category_form, to_form(Category.creation_changeset(%Category{}, %{})))
     |> assign(:category_form_mode, :new)}
  end

  def handle_event("toggle_category_active", %{"id" => id}, socket) do
    category = find_category(socket, id)

    {:ok, _} =
      Catalog.update_category(socket.assigns.current_scope, category, %{
        "active" => !category.active
      })

    {:noreply, socket |> reload_menu() |> broadcast_menu_updated()}
  end

  def handle_event("archive_category", %{"id" => id}, socket) do
    category = find_category(socket, id)
    {:ok, _} = Catalog.archive_category(socket.assigns.current_scope, category)
    {:noreply, socket |> reload_menu() |> broadcast_menu_updated()}
  end

  ## Items

  def handle_event("open_item_form", %{"category-id" => category_id}, socket) do
    changeset = MenuItem.creation_changeset(%MenuItem{}, %{"category_id" => category_id})

    {:noreply,
     socket
     |> assign(:item_form, to_form(changeset, as: :item))
     |> assign(:item_form_target, {:new, category_id})}
  end

  def handle_event("open_item_form", %{"item-id" => item_id}, socket) do
    item = find_item(socket, item_id)

    changeset =
      MenuItem.update_changeset(item, %{
        "category_id" => item.category_id,
        "price_amount" => item.price |> Money.to_decimal() |> Decimal.to_string()
      })

    {:noreply,
     socket
     |> assign(:item_form, to_form(changeset, as: :item))
     |> assign(:item_form_target, {:edit, item})}
  end

  def handle_event("cancel_item_form", _params, socket) do
    {:noreply,
     socket
     |> cancel_all_uploads()
     |> assign(:item_form, nil)
     |> assign(:item_form_target, nil)}
  end

  def handle_event("validate_item", %{"item" => params}, socket) do
    changeset = socket |> item_changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :item_form, to_form(changeset, as: :item))}
  end

  def handle_event("save_item", %{"item" => params}, socket) do
    venue = socket.assigns.current_scope.venue

    case parse_price(params["price_amount"], venue.currency) do
      {:ok, price} ->
        attrs = params |> Map.put("price", price) |> put_photo_url(socket)
        do_save_item(socket, attrs, params["category_id"])

      :error ->
        changeset =
          socket
          |> item_changeset(params)
          |> Ecto.Changeset.add_error(:price, gettext("must be a valid amount"))
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :item_form, to_form(changeset, as: :item))}
    end
  end

  def handle_event("toggle_item_available", %{"id" => id}, socket) do
    item = find_item(socket, id)
    {:ok, _} = Catalog.set_availability(socket.assigns.current_scope, item, !item.available_today)
    {:noreply, socket |> reload_menu() |> broadcast_menu_updated()}
  end

  def handle_event("archive_item", %{"id" => id}, socket) do
    item = find_item(socket, id)
    {:ok, _} = Catalog.archive_item(socket.assigns.current_scope, item)
    {:noreply, socket |> reload_menu() |> broadcast_menu_updated()}
  end

  def handle_event("reorder", %{"ids" => ids, "scope" => "categories"}, socket) do
    {:ok, _} = Catalog.reorder_categories(socket.assigns.current_scope, ids)
    {:noreply, socket |> reload_menu() |> broadcast_menu_updated()}
  end

  def handle_event(
        "reorder",
        %{"ids" => ids, "scope" => "items", "category_id" => category_id},
        socket
      ) do
    category = find_category(socket, category_id)
    {:ok, _} = Catalog.reorder_items(socket.assigns.current_scope, category, ids)
    {:noreply, socket |> reload_menu() |> broadcast_menu_updated()}
  end

  ## Daily limits

  def handle_event("save_daily_limit", %{"item-id" => id, "limit_qty" => limit_qty}, socket) do
    case Integer.parse(limit_qty) do
      {qty, ""} when qty > 0 ->
        item = find_item(socket, id)
        {:ok, _} = Catalog.set_daily_limit(socket.assigns.current_scope, item, qty)
        {:noreply, reload_menu(socket)}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Enter a whole number greater than zero."))}
    end
  end

  def handle_event("clear_daily_limit", %{"item-id" => id}, socket) do
    item = find_item(socket, id)
    {:ok, _} = Catalog.clear_daily_limit(socket.assigns.current_scope, item)
    {:noreply, reload_menu(socket)}
  end

  ## Helpers

  defp do_save_item(socket, attrs, category_id) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.item_form_target do
        {:new, _category_id} ->
          Catalog.create_item(scope, find_category(socket, category_id), attrs)

        {:edit, item} ->
          with {:ok, item} <- maybe_move_category(socket, item, category_id) do
            Catalog.update_item(scope, item, attrs)
          end
      end

    case result do
      {:ok, _item} ->
        {:noreply,
         socket
         |> cancel_all_uploads()
         |> reload_menu()
         |> broadcast_menu_updated()
         |> assign(:item_form, nil)
         |> assign(:item_form_target, nil)
         |> put_flash(:info, gettext("Item saved."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :item_form, to_form(changeset, as: :item))}
    end
  end

  defp maybe_move_category(_socket, item, category_id) when category_id == item.category_id,
    do: {:ok, item}

  defp maybe_move_category(socket, item, category_id) do
    Catalog.move_item_to_category(
      socket.assigns.current_scope,
      item,
      find_category(socket, category_id)
    )
  end

  defp category_changeset(socket, params) do
    case socket.assigns.category_form_mode do
      {:edit, id} -> Category.update_changeset(find_category(socket, id), params)
      :new -> Category.creation_changeset(%Category{}, params)
    end
  end

  defp item_changeset(socket, params) do
    case socket.assigns.item_form_target do
      {:edit, item} -> MenuItem.update_changeset(item, params)
      {:new, _category_id} -> MenuItem.creation_changeset(%MenuItem{}, params)
    end
  end

  defp find_category(socket, id),
    do: Enum.find_value(socket.assigns.menu, fn {c, _} -> if c.id == id, do: c end)

  defp find_item(socket, id), do: find_item_in_menu(socket.assigns.menu, id)

  defp find_item_in_menu(menu, id) do
    menu
    |> Enum.flat_map(fn {_category, items} -> items end)
    |> Enum.find(&(&1.id == id))
  end

  defp filtered_menu(menu, search, filter_category_id) do
    menu
    |> Enum.filter(fn {category, _items} -> filter_category_id in [nil, category.id] end)
    |> Enum.map(fn {category, items} ->
      {category, Enum.filter(items, &item_matches_search?(&1, search))}
    end)
  end

  defp out_of_stock_count(menu, daily_limits) do
    menu
    |> Enum.flat_map(fn {_category, items} -> items end)
    |> Enum.count(fn item ->
      limit = Map.get(daily_limits, item.id)
      !item.available_today or (limit && DailyItemLimit.remaining(limit) <= 0)
    end)
  end

  defp availability_label(%{available_today: false}, _limit), do: gettext("Off today")

  defp availability_label(_item, nil), do: gettext("Available")

  defp availability_label(_item, limit) do
    gettext("%{remaining} Available", remaining: DailyItemLimit.remaining(limit))
  end

  defp item_matches_search?(_item, ""), do: true

  defp item_matches_search?(item, search) do
    String.contains?(String.downcase(item.name), String.downcase(search))
  end

  defp parse_price(nil, _currency), do: :error

  defp parse_price(amount_str, currency) do
    case Decimal.parse(amount_str) do
      {decimal, ""} -> {:ok, Money.new!(currency, decimal)}
      _ -> :error
    end
  end

  defp put_photo_url(attrs, socket) do
    case consume_uploaded_entries(socket, :photo, fn %{key: key}, _entry ->
           {:ok, Storage.public_url(key)}
         end) do
      [url | _] -> Map.put(attrs, "photo_url", url)
      [] -> attrs
    end
  end

  defp cancel_all_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.photo.entries, socket, fn entry, socket ->
      cancel_upload(socket, :photo, entry.ref)
    end)
  end

  defp reload_menu(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:menu, Catalog.list_menu(scope))
    |> assign(:daily_limits, Catalog.list_daily_limits(scope))
  end

  defp broadcast_menu_updated(socket) do
    Phoenix.PubSub.broadcast(
      Tabletap.PubSub,
      "venue:#{socket.assigns.current_scope.venue.id}:menu",
      :menu_updated
    )

    socket
  end

  defp upload_error_to_string(:too_large), do: gettext("Photo is too large (max 6MB).")
  defp upload_error_to_string(:not_accepted), do: gettext("Unsupported file type.")
  defp upload_error_to_string(:too_many_files), do: gettext("Only one photo allowed.")
  defp upload_error_to_string(_), do: gettext("Upload failed.")
end

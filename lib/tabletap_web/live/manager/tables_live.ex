defmodule TabletapWeb.Manager.TablesLive do
  @moduledoc """
  Manager-facing table management (build-plan.md Feature 06): create/edit
  tables, rotate a table's QR token (invalidating the old printed code —
  design-qa.md Q7), archive (never delete — Q41), and jump to the
  printable QR sheet. Each table's live `/t/:qr_token` link is shown so a
  manager can test a code without printing.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Tenants
  alias Tabletap.Tenants.Table

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:tables}
      venues={@venues}
    >
      <div class="flex items-center justify-between flex-wrap gap-4 mb-2">
        <h1 class="text-2xl font-bold">{gettext("Tables")}</h1>
        <.link
          :if={@tables != []}
          navigate={~p"/tables/print"}
          class="btn btn-outline btn-sm"
        >
          <.icon name="hero-printer" class="size-4" /> {gettext("Print QR sheet")}
        </.link>
      </div>
      <p class="text-sm text-base-content/60 mb-6 max-w-prose">
        {gettext(
          "Each table gets its own QR code. Print the sheet, laminate it, and place one on every table. Rotating a code instantly disables the old printout."
        )}
      </p>

      <form
        id="table-form"
        phx-submit="save_table"
        phx-change="validate_table"
        class="mb-8 rounded-box bg-base-100 shadow-sm p-5"
      >
        <h2 class="font-semibold mb-3">
          {if @form_mode == :new, do: gettext("New table"), else: gettext("Edit table")}
        </h2>
        <div class="grid gap-3 sm:grid-cols-3 items-end">
          <.input
            field={@form[:number]}
            type="text"
            label={gettext("Number")}
            placeholder={gettext("e.g. 12 or A3")}
          />
          <.input
            field={@form[:label]}
            type="text"
            label={gettext("Label (optional)")}
            placeholder={gettext("e.g. Window booth")}
          />
          <.input field={@form[:active]} type="checkbox" label={gettext("Active")} />
        </div>
        <div class="flex gap-2 mt-3">
          <button type="submit" class="btn btn-primary btn-sm">
            {if @form_mode == :new, do: gettext("Add table"), else: gettext("Save changes")}
          </button>
          <button
            :if={@form_mode != :new}
            type="button"
            phx-click="cancel_edit"
            class="btn btn-ghost btn-sm"
          >
            {gettext("Cancel")}
          </button>
        </div>
      </form>

      <div class="space-y-3">
        <div
          :for={table <- @tables}
          id={"table-#{table.id}"}
          class="rounded-box bg-base-100 shadow-sm p-4 flex items-center justify-between gap-3 flex-wrap"
        >
          <div class="flex items-center gap-2 flex-wrap min-w-0">
            <span class="font-semibold text-lg">{gettext("Table %{number}", number: table.number)}</span>
            <span :if={table.label} class="text-sm text-base-content/60">{table.label}</span>
            <span :if={!table.active} class="badge badge-warning badge-sm">
              {gettext("Inactive")}
            </span>
          </div>

          <div class="flex items-center gap-2 flex-wrap">
            <a
              href={url(~p"/t/#{table.qr_token}")}
              target="_blank"
              rel="noopener"
              class="text-xs text-base-content/50 hover:text-base-content font-mono truncate max-w-[12rem]"
              title={gettext("Open this table's live QR link")}
            >
              /t/{String.slice(table.qr_token, 0, 8)}…
            </a>
            <button
              type="button"
              phx-click="edit_table"
              phx-value-id={table.id}
              class="btn btn-xs btn-ghost"
            >
              {gettext("Edit")}
            </button>
            <button
              type="button"
              phx-click="rotate_token"
              phx-value-id={table.id}
              data-confirm={
                gettext("Rotate this table's QR code? The current printout will stop working.")
              }
              class="btn btn-xs btn-ghost"
            >
              {gettext("Rotate QR")}
            </button>
            <button
              type="button"
              phx-click="archive_table"
              phx-value-id={table.id}
              data-confirm={gettext("Archive this table? It'll be hidden from the floor.")}
              class="btn btn-xs btn-ghost text-error"
            >
              {gettext("Archive")}
            </button>
          </div>
        </div>

        <p :if={@tables == []} class="text-sm text-base-content/50">
          {gettext("No tables yet — add one above to generate its QR code.")}
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
     |> assign(:form, to_form(Table.creation_changeset(%Table{}, %{})))
     |> assign(:form_mode, :new)
     |> reload_tables()}
  end

  @impl true
  def handle_event("validate_table", %{"table" => params}, socket) do
    case table_changeset(socket, params) do
      {:ok, changeset} ->
        {:noreply, assign(socket, :form, to_form(Map.put(changeset, :action, :validate)))}

      :error ->
        {:noreply, reset_form_not_found(socket)}
    end
  end

  def handle_event("save_table", %{"table" => params}, socket) do
    scope = socket.assigns.current_scope

    result =
      case socket.assigns.form_mode do
        :new ->
          Tenants.create_table(scope, params)

        {:edit, id} ->
          case find_table(socket, id) do
            nil -> :not_found
            table -> Tenants.update_table(scope, table, params)
          end
      end

    case result do
      {:ok, _table} ->
        {:noreply,
         socket
         |> reload_tables()
         |> assign(:form, to_form(Table.creation_changeset(%Table{}, %{})))
         |> assign(:form_mode, :new)
         |> put_flash(:info, gettext("Table saved."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}

      :not_found ->
        {:noreply, reset_form_not_found(socket)}
    end
  end

  def handle_event("edit_table", %{"id" => id}, socket) do
    case find_table(socket, id) do
      nil ->
        {:noreply, reset_form_not_found(socket)}

      table ->
        {:noreply,
         socket
         |> assign(:form, to_form(Table.update_changeset(table, %{})))
         |> assign(:form_mode, {:edit, id})}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:form, to_form(Table.creation_changeset(%Table{}, %{})))
     |> assign(:form_mode, :new)}
  end

  def handle_event("rotate_token", %{"id" => id}, socket) do
    case find_table(socket, id) do
      nil ->
        {:noreply, not_found_flash(socket)}

      table ->
        {:ok, _table} = Tenants.rotate_qr_token(socket.assigns.current_scope, table)

        {:noreply,
         socket
         |> reload_tables()
         |> put_flash(:info, gettext("QR code rotated — reprint this table's code."))}
    end
  end

  def handle_event("archive_table", %{"id" => id}, socket) do
    case find_table(socket, id) do
      nil ->
        {:noreply, not_found_flash(socket)}

      table ->
        {:ok, _table} = Tenants.archive_table(socket.assigns.current_scope, table)
        {:noreply, socket |> reload_tables() |> put_flash(:info, gettext("Table archived."))}
    end
  end

  # {:ok, changeset} | :error — :error means `id` (from `form_mode`) no
  # longer resolves in the venue's own scoped list, e.g. archived from
  # another tab/device between opening the edit form and this event. Never
  # crashes on a stale or forged id (code-standards.md "No Repo.get! on
  # user-supplied ids... use get_* returning nil, handled").
  defp table_changeset(socket, params) do
    case socket.assigns.form_mode do
      {:edit, id} ->
        case find_table(socket, id) do
          nil -> :error
          table -> {:ok, Table.update_changeset(table, params)}
        end

      :new ->
        {:ok, Table.creation_changeset(%Table{}, params)}
    end
  end

  defp find_table(socket, id), do: Enum.find(socket.assigns.tables, &(&1.id == id))

  defp not_found_flash(socket) do
    socket
    |> reload_tables()
    |> put_flash(:error, gettext("That table is no longer available."))
  end

  # Same as not_found_flash/1, plus resetting the form back to :new —
  # for handlers where the vanished table was the one currently open in
  # the edit form, so continuing to show it makes no sense.
  defp reset_form_not_found(socket) do
    socket
    |> not_found_flash()
    |> assign(:form, to_form(Table.creation_changeset(%Table{}, %{})))
    |> assign(:form_mode, :new)
  end

  defp reload_tables(socket) do
    assign(socket, :tables, Tenants.list_tables(socket.assigns.current_scope))
  end
end

defmodule TabletapWeb.Manager.TablePrintLive do
  @moduledoc """
  Printable QR sheet (build-plan.md Feature 06): a grid of per-table SVG
  QR codes, each captioned with the table number, the venue name, and the
  plain-text scan URL — the anti-phishing cue from design-qa.md Q7 ("a
  legit sheet shows the venue name and our domain in plain text").

  `:high` error correction so a laminated, stained code still scans
  (library-docs.md). Screen chrome is `print:hidden`; each card avoids
  page breaks so codes never split across sheets.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Tenants

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-white text-black">
      <div class="print:hidden border-b border-base-300 px-4 py-3 flex items-center justify-between gap-3 flex-wrap">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/tables"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to tables")}
          </.link>
          <span class="text-sm text-base-content/60">
            {gettext("%{count} table QR codes", count: length(@tables))}
          </span>
        </div>
        <button id="print-sheet" phx-hook=".Print" type="button" class="btn btn-primary btn-sm">
          <.icon name="hero-printer" class="size-4" /> {gettext("Print")}
        </button>
      </div>

      <div class="p-6 print:p-0">
        <div class="grid grid-cols-2 sm:grid-cols-3 print:grid-cols-2 gap-6">
          <div
            :for={%{table: table, svg: svg, scan_url: scan_url} <- @codes}
            id={"print-table-#{table.id}"}
            class="break-inside-avoid border border-black/10 rounded-lg p-4 text-center flex flex-col items-center gap-2"
          >
            <p class="text-2xl font-extrabold">{gettext("Table %{number}", number: table.number)}</p>
            <div class="w-40 [&_svg]:w-full [&_svg]:h-auto">{Phoenix.HTML.raw(svg)}</div>
            <p class="text-sm font-medium">{@venue.name}</p>
            <p class="text-[0.65rem] text-black/50 break-all font-mono">{scan_url}</p>
          </div>
        </div>

        <p :if={@tables == []} class="text-center text-base-content/50 py-12">
          {gettext("No tables to print yet — add some first.")}
        </p>
      </div>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".Print">
      export default {
        mounted() {
          this.el.addEventListener("click", () => window.print())
        }
      }
    </script>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    tables = Tenants.list_tables(scope)

    codes =
      Enum.map(tables, fn table ->
        scan_url = url(~p"/t/#{table.qr_token}")
        %{table: table, svg: qr_svg(scan_url), scan_url: scan_url}
      end)

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:venue, scope.venue)
     |> assign(:tables, tables)
     |> assign(:codes, codes)}
  end

  # :high error correction — physical, laminated codes get dirty
  # (library-docs.md "qr_code" rules).
  defp qr_svg(scan_url) do
    {:ok, svg} =
      scan_url
      |> QRCode.create(:high)
      |> QRCode.render(:svg, %QRCode.Render.SvgSettings{
        qrcode_color: "#000000",
        background_color: "#ffffff",
        scale: 5
      })

    svg
  end
end

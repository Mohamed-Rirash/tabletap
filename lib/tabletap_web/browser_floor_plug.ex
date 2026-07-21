defmodule TabletapWeb.BrowserFloorPlug do
  @moduledoc """
  Best-effort browser floor (design-qa.md Q56 — "iOS Safari 15+ and
  evergreen Chrome/Android (~2 years back)"). Confirmed with the user: a
  **conservative** UA sniff that only blocks user agents it can
  confidently place below the floor — erring toward letting a real
  customer through rather than falsely blocking one. Anything this
  doesn't recognize (unusual UAs, bots, spoofed strings, desktop
  Firefox/Safari — never named by Q56's own floor) passes through
  untouched. This is a courtesy page, not a security gate.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  # iOS ties its WebKit engine version to the OS release, not to
  # whichever browser wraps it (Apple requires every iOS browser —
  # Safari, Chrome-iOS, Firefox-iOS — to use the system WebKit) — so the
  # OS version token in the UA is the right signal for *any* iOS
  # browser, not just Safari's own. Safari 15 shipped with iOS 15, so
  # "OS 14 and below" is exactly the Q56 floor, not an estimate.
  @ios_os_version ~r/CPU (?:iPhone )?OS (\d+)_/
  @ios_floor 14

  # Chrome/Chromium major version (also present in Chromium-based Edge's
  # own UA, so an old Edge is caught by the same check). No exact "2
  # years back" release date to pin against a moving target, so this is
  # picked deliberately low — comfortably older than any real floor —
  # so it only ever catches genuinely ancient browsers. Doesn't
  # self-update; bump occasionally.
  @chrome_version ~r/Chrom(?:e|ium)\/(\d+)/
  @chrome_floor 100

  @exempt_paths ["/unsupported-browser"]

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.request_path in @exempt_paths do
      conn
    else
      user_agent = conn |> get_req_header("user-agent") |> List.first() || ""

      if below_floor?(user_agent) do
        conn |> redirect(to: "/unsupported-browser") |> halt()
      else
        conn
      end
    end
  end

  defp below_floor?(ua), do: trident_or_msie?(ua) or old_ios?(ua) or old_chrome?(ua)

  defp trident_or_msie?(ua), do: ua =~ "Trident" or ua =~ "MSIE"

  defp old_ios?(ua) do
    with [_, version] <- Regex.run(@ios_os_version, ua),
         {major, _} <- Integer.parse(version) do
      major <= @ios_floor
    else
      _ -> false
    end
  end

  defp old_chrome?(ua) do
    with [_, version] <- Regex.run(@chrome_version, ua),
         {major, _} <- Integer.parse(version) do
      major < @chrome_floor
    else
      _ -> false
    end
  end
end

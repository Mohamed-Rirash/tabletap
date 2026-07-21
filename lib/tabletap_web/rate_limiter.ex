defmodule TabletapWeb.RateLimiter do
  @moduledoc """
  Fixed-window per-IP rate limit. Started for auth actions that send
  email (magic link, password reset — design-qa.md Q47: the login form
  must throttle sends per email address, see
  `Tabletap.Accounts.deliver_login_instructions/2`, and per IP, here, so
  an attacker can't bomb a victim's inbox through it), extended in
  build-plan.md Feature 22 to the public guest-facing QR/cart/checkout
  routes — nothing on that path was throttled at all before.

  Budgets are deliberately generous everywhere (`check/2`'s `opts`
  override the default 5-per-60s) — this is a courtesy abuse guard, not
  a security boundary, and venue wifi commonly puts many real customers
  behind the same NAT'd IP; erring toward letting a real customer
  through beats blocking one over stopping a scripted flood.

  ETS-backed, in-process — no external dependency for something this small.
  Not distributed: on a multi-node deploy each node enforces its own window,
  which is an acceptable looseness for an abuse guard (not a security boundary).
  """
  use GenServer

  @table __MODULE__
  @window_ms 60_000
  @max_per_window 5

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Returns `:ok` and records the attempt if `key` is under the limit for the
  current window, or `:rate_limited` otherwise. `key` is normally a client
  IP string, but is deliberately just a term so it composes with per-action
  keys (e.g. `{:login, ip}`) if a limited action needs its own budget.

  `opts`:
  - `:window_ms` — window length, default 60_000
  - `:max` — attempts allowed per window, default 5
  """
  def check(key, opts \\ []) do
    window_ms = Keyword.get(opts, :window_ms, @window_ms)
    max = Keyword.get(opts, :max, @max_per_window)
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, count, window_start}] when now - window_start < window_ms ->
        if count < max do
          :ets.update_element(@table, key, {2, count + 1})
          :ok
        else
          :rate_limited
        end

      _ ->
        :ets.insert(@table, {key, 1, now})
        :ok
    end
  end

  @doc """
  Best-effort client IP for a LiveView `socket`: prefers `x-forwarded-for`
  (set by a proxy in front of the app — Fly.io per architecture.md) and
  falls back to the raw peer address locally. Only meaningful once the
  socket is connected (call from `mount/3` guarded by `connected?/1`) —
  connect_info doesn't exist on the initial static render.
  """
  def client_ip(socket) do
    x_headers = Phoenix.LiveView.get_connect_info(socket, :x_headers) || []

    case List.keyfind(x_headers, "x-forwarded-for", 0) do
      {_, value} ->
        value |> String.split(",") |> List.first() |> String.trim()

      nil ->
        case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
          %{address: address} -> address |> :inet.ntoa() |> to_string()
          _ -> "unknown"
        end
    end
  end

  @doc """
  Same best-effort IP resolution as `client_ip/1`, for a plain
  `Plug.Conn` (build-plan.md Feature 22's `Public.TableController`,
  which has no LiveView socket/connect_info to read).
  """
  def client_ip_from_conn(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [value | _] ->
        value |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end

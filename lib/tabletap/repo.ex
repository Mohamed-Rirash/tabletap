defmodule Tabletap.Repo do
  @moduledoc """
  Tenant-enforcing Repo (architecture.md "Multi-Tenancy", library-docs.md
  "Ecto — Tenant-Enforcing Repo"). Every tenant-owned query must carry
  `org_id` (injected automatically once `put_org_id/1` has been called for
  the current process) or explicit `skip_org_id: true`.

  `put_org_id/1` is called exactly once per request/LiveView mount, by the
  scope-resolution code in `TabletapWeb.UserAuth` — context code never
  calls it directly.

  This only guards **query-based** reads/bulk-writes (`all`, `one`, `get`,
  `update_all`, `delete_all`) — `prepare_query/3` is not invoked for plain
  struct `insert/2`/`update/2`. Insert-side tenant correctness is instead
  enforced by the composite `(id, org_id)` foreign keys in the schema
  (code-standards.md): a membership or venue accidentally stamped with the
  wrong `org_id` fails the FK constraint at the database level.

  `skip_org_id: true` may appear only in `Tabletap.Accounts`,
  `Tabletap.Tenants` (org/venue resolution), and platform-admin code —
  everywhere else it fails code review (code-standards.md "Tenancy Rules").
  """
  use Ecto.Repo,
    otp_app: :tabletap,
    adapter: Ecto.Adapters.Postgres

  require Ecto.Query

  @tenant_key {__MODULE__, :org_id}

  @doc "Sets the current process's tenant for the rest of this request/mount."
  def put_org_id(org_id), do: Process.put(@tenant_key, org_id)

  @doc "Reads the current process's tenant, or `nil` if none has been set."
  def get_org_id, do: Process.get(@tenant_key)

  @impl true
  def default_options(_operation) do
    [org_id: get_org_id()]
  end

  @impl true
  def prepare_query(_operation, query, opts) do
    cond do
      opts[:skip_org_id] || opts[:schema_migration] ->
        {query, opts}

      org_id = opts[:org_id] ->
        {Ecto.Query.where(query, org_id: ^org_id), opts}

      true ->
        raise """
        expected org_id or skip_org_id: true to be set — a query reached \
        Tabletap.Repo without tenant scope.

        Call Tabletap.Repo.put_org_id/1 once per request (already done by \
        TabletapWeb.UserAuth for authenticated requests), or pass \
        skip_org_id: true explicitly if this query is genuinely tenant-free \
        (only allowed in Accounts, Tenants, and platform-admin code — \
        code-standards.md "Tenancy Rules").
        """
    end
  end
end

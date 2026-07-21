defmodule Tabletap.OpsTest do
  @moduledoc """
  `Tabletap.Ops.check_order_flow/0` (build-plan.md Feature 21) — the
  synthetic order-flow health check, backed by a well-known-slugged
  org/venue created lazily on first call. DB-backed via the sandboxed
  `Tabletap.Repo`, so (unlike `Payments.GatewayHealth`'s raw ETS state)
  this is safe under `async: true` — each test's own sandboxed
  transaction is isolated from every other test's.
  """
  use Tabletap.DataCase, async: true

  import Ecto.Query

  alias Tabletap.Admin
  alias Tabletap.Ops
  alias Tabletap.Repo
  alias Tabletap.Tenants.{Org, Venue}

  test "creates the synthetic fixture on first call and returns :ok" do
    assert :ok = Ops.check_order_flow()

    org = Repo.get_by(Org, [slug: "tabletap-synthetic-healthcheck"], skip_org_id: true)
    assert org.synthetic

    venue = Repo.get_by(Venue, [slug: "tabletap-synthetic-healthcheck"], skip_org_id: true)
    assert venue.org_id == org.id
  end

  test "is idempotent — a second call reuses the same fixture, no duplicates" do
    assert :ok = Ops.check_order_flow()
    assert :ok = Ops.check_order_flow()

    orgs =
      Repo.all(from(o in Org, where: o.slug == "tabletap-synthetic-healthcheck"),
        skip_org_id: true
      )

    assert length(orgs) == 1
  end

  test "the synthetic org is excluded from Admin.list_tenants/0" do
    Ops.check_order_flow()

    refute Admin.list_tenants() |> Enum.any?(& &1.org.synthetic)
  end
end

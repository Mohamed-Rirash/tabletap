defmodule Tabletap.Ordering.Workers.SweepAbandonedCarts do
  @moduledoc """
  Marks carts inactive for 24h+ as `abandoned` (build-plan.md Feature 07;
  design-qa.md Q50 "abandoned carts swept after 24h"). Rows are kept, not
  deleted — abandoned-cart data has analytics value later (Feature 18)
  and archive-never-delete is the house style (code-standards.md).

  Runs cross-tenant, once per scheduled tick — but never with
  `skip_org_id: true` (`Ordering` isn't on that exception list,
  code-standards.md "Tenancy Rules"). Instead it loops
  `Tenants.list_org_ids/0` and calls `Repo.put_org_id/1` once per org
  before each normal, tenant-scoped `update_all` — `Tabletap.Repo`'s
  `prepare_query/3` injects that org's `where: org_id == ^id` clause
  automatically (repo.ex), so every write here goes through the exact
  same enforcement path a request-scoped query would.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias Tabletap.Ordering.Cart
  alias Tabletap.{Repo, Tenants}

  @stale_after_seconds 60 * 60 * 24

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_seconds, :second)

    total =
      Tenants.list_org_ids()
      |> Enum.reduce(0, fn org_id, acc ->
        Repo.put_org_id(org_id)

        {count, _} =
          Repo.update_all(
            from(c in Cart, where: c.status == :active and c.updated_at < ^cutoff),
            set: [status: :abandoned]
          )

        acc + count
      end)

    :telemetry.execute([:tabletap, :ordering, :carts_swept], %{count: total}, %{})

    :ok
  end
end

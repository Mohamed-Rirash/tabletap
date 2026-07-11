defmodule Tabletap.ObanRepo do
  @moduledoc """
  Plain (non-tenant-enforcing) Ecto Repo for Oban's own internal
  bookkeeping (`oban_jobs`, `oban_peers`) — platform infrastructure, not
  tenant-owned data. Oban's queue/peer-leadership machinery runs in its own
  supervised processes, never inside a web request, so there is no
  per-process `org_id` for it to inherit from `Tabletap.Repo.put_org_id/1`.

  Same physical database as `Tabletap.Repo` (see config/*.exs — identical
  connection settings), deliberately without that Repo's
  `prepare_query`/`default_options` tenant guard. Not listed in
  `ecto_repos`, so `mix ecto.*` tasks don't try to migrate it separately —
  it's a second Ecto Repo *module*, not a second database.
  """
  use Ecto.Repo,
    otp_app: :tabletap,
    adapter: Ecto.Adapters.Postgres
end

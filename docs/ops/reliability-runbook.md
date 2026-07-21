# Reliability & Ops Runbook

build-plan.md Feature 21 ("Reliability & Ops Hardening"). This document covers the two pieces of that feature that are genuine **deployment/infrastructure decisions**, not application code — they can't be provisioned inside a coding sandbox, so this is written as what a human operator configures once real infra exists, not a claim that any of it is already running. The application-code half of Feature 21 (clustering config, the stuck-order watchdog, degradation banners, telemetry) is real, shipped code — see `context/progress-tracker.md`'s Feature 21 entry for that half.

---

## 1. Two-node clustered deploy + load balancer

The app-side half already exists: `DNSCluster` is wired in `lib/tabletap/application.ex`, reading `config :tabletap, :dns_cluster_query` — set via the `DNS_CLUSTER_QUERY` environment variable in `config/runtime.exs`'s prod block. Verified locally (two BEAM nodes, connected, `Phoenix.PubSub.broadcast/3` reaching a subscriber on the other node — see progress-tracker.md's Feature 21 Commit 1 entry). What's left is purely deploy-platform configuration:

**On Fly.io** (architecture.md's named default target):
- Scale to ≥2 machines: `fly scale count 2` (or higher, per real traffic).
- Set `DNS_CLUSTER_QUERY=<app-name>.internal` as a deploy secret/env var — Fly's own private 6PN network resolves that DNS name to every running machine's private IPv6 address, which is exactly what `DNSCluster` polls.
- Fly's own edge already load-balances across machines in a region by default — no separate load balancer to stand up.
- Rolling deploys are Fly's default (`fly deploy` drains and replaces machines one at a time) — LiveView clients on a draining machine reconnect automatically to a surviving one; the client-side reconnect logic already ships (Feature 20's `#offline-banner` + LiveView's own built-in reconnect).

**On any other Docker host:**
- `DNS_CLUSTER_QUERY` needs a DNS name that resolves to every running container's address — a Kubernetes headless service, an ECS Cloud Map namespace, or equivalent. `DNSCluster`'s own polling (`libcluster`'s simpler modern replacement) works with anything that answers a plain DNS query with multiple A/AAAA records.
- A real load balancer (ALB, an nginx/HAProxy tier, Cloudflare, etc.) in front, health-checking `GET /healthz` (already exists, no auth, no DB dependency — a pure liveness probe).

**Verifying it's actually working once deployed:** confirm `Node.list()` (via a remote shell / `fly ssh console` + `iex --remsh`) shows every other running node, and that a PubSub-driven UI update (an order status change, a low-stock alert) reaches a client connected to a *different* node than the one that made the write.

---

## 2. Managed Postgres HA + WAL/PITR

architecture.md's own target: "managed Postgres, synchronous standby + automated failover, WAL/PITR (RPO ≈ 0, RTO minutes), backups restore-tested on a schedule." This app has no special requirements beyond what any managed Postgres provider offers out of the box — the specifics:

**On Fly.io:** Fly Postgres (or, preferably for this workload, a dedicated managed provider — Fly's own docs now recommend Supabase/Neon/RDS-style providers over self-managed Fly Postgres clusters for production HA). Whichever is chosen, the settings that matter:
- **Synchronous standby, same region, different zone** — RPO ≈ 0 (no committed transaction is lost on primary failure).
- **Automated failover** enabled, with a target failover time in the tens-of-seconds range, not minutes.
- **WAL archiving + PITR** enabled with a retention window covering at minimum the 90-day offboarding/180-day dispute-record windows this app's own `Tabletap.Offboarding` context already assumes data survives that long (Feature 19) — a PITR retention shorter than that would mean a restore drill 100 days out can't actually recover a since-purged dispute record's window, even though the *live* data is unaffected.
- **`Tabletap.Repo` config already supports this with zero code changes** — `DATABASE_URL` + `POOL_SIZE` (`config/runtime.exs`) point at whatever endpoint the provider gives you; a managed failover just means that endpoint's DNS/IP moves underneath the app, which Ecto's connection pool already recovers from via its own reconnect-on-error behavior.

**Restore-testing on a schedule:** the drill in the next section is the *mechanism* proof; a real production schedule should re-run the equivalent (restore the latest automated backup into a scratch instance, verify row counts / a few known rows, tear down) monthly at minimum, more often for a business this payment-critical.

---

## 3. Restore drill — real, executed locally (2026-07-21)

This is a genuine `pg_dump`/drop/`pg_restore` cycle actually run against the local dev Postgres (`tabletap_dev`, in the project's own `docker-compose.yml` container), **not** a real managed-Postgres-HA failover drill — clearly labeled as a downscaled local substitute. It proves the backup/restore *mechanism* works end-to-end against this exact schema; it does not exercise automated failover, a standby promotion, or WAL-based point-in-time recovery, none of which exist to test without real managed infrastructure. A real production drill needs to additionally verify: standby promotion time, DNS/connection-string cutover, and PITR to an arbitrary point (not just "restore the latest full backup").

### What was done

1. Inserted one clearly-labeled marker row (`orgs.slug = "restore-drill-marker"`) so the restore could be verified against a specific, known row — not just "the table exists."
2. **Backup** — a full logical dump in custom format (`-Fc`, the standard `pg_restore`-compatible format), run via the Postgres container's own matching-version tools (not a mismatched host client):
   ```
   docker exec -e PGPASSWORD=postgres tabletap-db-1 \
     pg_dump -U postgres -Fc -d tabletap_dev > tabletap_dev.dump
   ```
   **Real result: 0.28s, 152 KB** (43 tables, this environment's small dev dataset).
3. **Simulated disaster** — the database was dropped entirely, not just truncated:
   ```
   psql -U postgres -d postgres -c "DROP DATABASE tabletap_dev;"
   ```
4. **Restore** — a fresh empty database, then a full restore from the dump taken in step 2:
   ```
   psql -U postgres -d postgres -c "CREATE DATABASE tabletap_dev;"
   docker cp tabletap_dev.dump tabletap-db-1:/tmp/tabletap_dev.dump
   docker exec -e PGPASSWORD=postgres tabletap-db-1 \
     pg_restore -U postgres -d tabletap_dev --no-owner /tmp/tabletap_dev.dump
   ```
   **Real result: 1.36s** — this is the local-equivalent RTO for a dataset this size; it scales with data volume, not a fixed constant, so it isn't a stand-in for a real production RTO estimate.
5. **Verified**, not assumed: post-restore, all 43 tables were back, the exact marker row (`id`, `name`, `slug`) matched what was inserted pre-drill byte-for-byte, `schema_migrations` showed every migration (including the one landed earlier this same session) still recorded, `mix ecto.migrate` reported "Migrations already up" (no drift), and the app booted clean against the restored database (`mix run`).
6. The marker row was deleted afterward — this drill leaves no lasting artifact in the dev database.

### Honest gap to a real production drill

This exercised the *tooling* (`pg_dump`/`pg_restore` round-trip fidelity against this exact schema) on a single-instance, 10 MB, no-real-traffic database. A real managed-Postgres HA drill needs, additionally: killing the primary and timing automated standby promotion; confirming the app's connection pool recovers without a restart once the provider's DNS/endpoint repoints; and a PITR restore to a specific timestamp (not just "the latest backup"), verified against WAL-replayed data past that backup's own cutoff. None of that is exercisable without a real managed Postgres HA cluster provisioned — this local drill is offered as proof that the mechanism this codebase depends on (a standard `pg_dump`/`pg_restore` cycle, nothing schema-specific or exotic) works correctly, not as a substitute for that larger drill.

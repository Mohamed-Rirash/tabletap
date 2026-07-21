ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Tabletap.Repo, :manual)

# Tabletap.ObanRepo is a separate Ecto repo pointed at the same test
# database (see lib/tabletap/oban_repo.ex) — it needs its own sandbox
# mode/ownership, or `Oban.insert/1` calls commit for real instead of
# rolling back per test.
Ecto.Adapters.SQL.Sandbox.mode(Tabletap.ObanRepo, :manual)

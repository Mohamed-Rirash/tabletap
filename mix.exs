defmodule Tabletap.MixProject do
  use Mix.Project

  def project do
    [
      app: :tabletap,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Tabletap.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # Background jobs
      {:oban, "~> 2.23"},

      # Money — never floats, never bare integers (code-standards.md)
      {:ex_money, "~> 6.1"},
      {:ex_money_sql, "~> 2.0"},

      # Encrypted fields — per-venue wallet merchant credentials (design-qa.md Q57/Q58)
      {:cloak_ecto, "~> 1.3"},

      # Table QR generation
      {:qr_code, "~> 3.2"},

      # Web Push (VAPID) — waiter/manager alerts
      {:web_push_ex, "~> 0.2.0"},

      # Object storage — menu photos, venue logos
      {:ex_aws, "~> 2.7"},
      {:ex_aws_s3, "~> 2.5"},

      # IANA time zone database — DateTime.shift_zone!/2 needs one for any
      # zone besides Etc/UTC; Tenants.business_date/2 is the first caller
      # (code-standards.md, CONTEXT.md "Business day / cutoff"). `tz`, not
      # `tzdata`: tzdata's hackney ~> 1.17 requirement conflicts with
      # ex_aws's hackney ~> 4.0, and `tz` needs no HTTP client at all —
      # it reads tzdata straight from the OS (or a bundled release).
      {:tz, "~> 0.28"},

      # Dev/test
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.2", only: :test},
      {:dotenvy, "~> 1.1", only: [:dev, :test], runtime: true}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind tabletap", "esbuild tabletap"],
      "assets.deploy": [
        "tailwind tabletap --minify",
        "esbuild tabletap --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end

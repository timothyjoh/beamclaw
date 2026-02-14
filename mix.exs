defmodule BeamClaw.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamclaw,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      compilers: Mix.compilers(),
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {BeamClaw.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:finch, "~> 0.19"},
      {:yaml_elixir, "~> 2.9"},
      {:file_system, "~> 1.0"},
      {:phoenix, "~> 1.7"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:bandit, "~> 1.5"},
      {:nostrum, "~> 0.10", runtime: Mix.env() != :test},
      {:crontab, "~> 1.1"},
      {:libcluster, "~> 3.4"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end

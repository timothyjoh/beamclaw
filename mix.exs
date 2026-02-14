defmodule BeamClaw.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamclaw,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:file_system, "~> 1.0"}
    ]
  end
end

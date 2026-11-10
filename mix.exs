defmodule Messaging.MixProject do
  use Mix.Project

  def project do
    [
      app: :messaging,
      version: "0.1.0",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      mod: {Messaging.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  defp releases do
    [
      messaging: [
        applications: [opentelemetry_exporter: :permanent, opentelemetry: :temporary]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:jason, "~> 1.4"},
      {:plug_cowboy, "~> 2.7"},
      {:cowlib, "~> 2.19.0", override: true},
      {:mongodb_driver, "~> 1.4"},
      {:postgrex, "~> 0.19"},
      {:amqp, "~> 3.3"},
      {:events_contract, github: "discordia-grupo01/events-contract", tag: "v0.17.0"},
      {:req, "~> 0.5"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_api_experimental, "~> 0.6"},
      {:opentelemetry_experimental, "~> 0.6"},
      {:open_api_spex, "~> 3.21"},
      {:ymlr, "~> 5.0", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.1", only: :test}
    ]
  end
end

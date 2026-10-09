defmodule Mayfly.AWS.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/bmalum/mayfly_aws"

  def project do
    [
      app: :mayfly_aws,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Idempotency and a minimal signed DynamoDB client for Mayfly (Elixir on AWS Lambda)",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url, "Mayfly" => "https://elixir-aws-lambda.dev"}
      ],
      name: "Mayfly.AWS",
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"], source_ref: "v#{@version}"],
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit, :inets, :ssl, :public_key],
        plt_local_path: "_build/plts",
        plt_core_path: "_build/plts"
      ]
    ]
  end

  # :inets/:ssl are needed for HTTPS to DynamoDB. They are started lazily on
  # first use (Mayfly.AWS.HTTP), so they add nothing to cold start until an
  # idempotency check actually runs.
  def application do
    [extra_applications: [:logger, :crypto, :inets, :ssl, :public_key]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Until mayfly is on Hex, resolve it from the sibling checkout (or set MAYFLY_PATH).
      {:mayfly, path: System.get_env("MAYFLY_PATH", "../mayfly")},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end

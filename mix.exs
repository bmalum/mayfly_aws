defmodule Mayfly.AWS.MixProject do
  use Mix.Project

  @version "0.2.0"
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
        "AWS for Mayfly Lambda functions: idempotent handlers on DynamoDB; S3, SQS, SNS, SSM and Secrets Manager clients with no dependencies",
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
    # :inets/:ssl are started with the application (the per-app :load mode needs
    # Elixir >= 1.19). Starting them costs ~20-40 ms once at boot; the TLS
    # handshake itself happens on the first AWS call.
    [extra_applications: [:logger, :crypto, :inets, :ssl, :public_key]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Hex release by default. Set MAYFLY_PATH=/path/to/mayfly to develop against a
  # local checkout (CI does this until mayfly itself is on Hex).
  defp mayfly_dep do
    case System.get_env("MAYFLY_PATH") do
      nil -> {:mayfly, "~> 1.0.0-rc"}
      path -> {:mayfly, path: path}
    end
  end

  defp deps do
    [
      # Until mayfly is on Hex, resolve it from the sibling checkout (or set MAYFLY_PATH).
      mayfly_dep(),
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end

defmodule PhpBeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :phpbeam,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [extra_applications: [:logger]]
  end

  # hex registry unreachable from this network (Erlang TLS vs intercepting
  # CA) — git deps instead; hex works again once the chain is trusted
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:myxql, git: "https://github.com/elixir-ecto/myxql.git", tag: "v0.7.1"},
      {:db_connection,
       git: "https://github.com/elixir-ecto/db_connection.git", tag: "v2.10.1", override: true},
      {:decimal, git: "https://github.com/ericmj/decimal.git", tag: "v2.4.1", override: true},
      {:telemetry,
       git: "https://github.com/beam-telemetry/telemetry.git", tag: "v1.3.0", override: true}
    ]
  end

  defp escript do
    [main_module: PhpBeam.CLI, name: "phpx", path: "phpx"]
  end
end

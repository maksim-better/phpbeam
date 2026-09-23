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

  defp deps do
    [{:jason, "~> 1.4"}]
  end

  defp escript do
    [main_module: PhpBeam.CLI, name: "phpx", path: "phpx"]
  end
end

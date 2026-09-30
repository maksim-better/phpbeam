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
    [extra_applications: [:logger, :xmerl, :inets, :ssl, :ftp]]
  end

  # hex registry unreachable from this network (Erlang TLS vs intercepting
  # CA) — git deps instead; hex works again once the chain is trusted
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:exqlite,
       git: "https://github.com/elixir-sqlite/exqlite.git", tag: "v0.29.0", override: true},
      {:elixir_make,
       git: "https://github.com/elixir-lang/elixir_make.git", tag: "v0.9.0",
       runtime: false, override: true},
      {:cc_precompiler,
       git: "https://github.com/cocoa-xu/cc_precompiler.git", tag: "v0.1.9",
       runtime: false, override: true},
      {:epgsql, git: "https://github.com/epgsql/epgsql.git", tag: "4.8.0", override: true},
      {:myxql, git: "https://github.com/elixir-ecto/myxql.git", tag: "v0.7.1"},
      {:db_connection,
       git: "https://github.com/elixir-ecto/db_connection.git", tag: "v2.10.1", override: true},
      {:decimal, git: "https://github.com/ericmj/decimal.git", tag: "v2.4.1", override: true},
      {:telemetry,
       git: "https://github.com/beam-telemetry/telemetry.git", tag: "v1.3.0", override: true}
    ]
  end

  defp escript do
    # -pa keeps the local deps on the code path so NIF-backed deps
    # (exqlite) resolve :code.priv_dir to the real priv dir — escripts
    # cannot embed .so files, and this phpx is a same-host dev tool
    dep_ebins =
      Path.wildcard(Path.join(File.cwd!(), "_build/dev/lib/*/ebin"))
      |> Enum.join(" ")

    [main_module: PhpBeam.CLI, name: "phpx", path: "phpx", emu_args: "-pa " <> dep_ebins]
  end
end

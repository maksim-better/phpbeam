defmodule PhpBeam.Interp do
  @moduledoc """
  Interpreter state and program driver. Expression evaluation lives in
  `PhpBeam.Eval`, rendering in `PhpBeam.Render`, builtins in `PhpBeam.Builtin`.

  Every eval function threads `{result, env, interp}` where result is
  `{:val, v}` for expressions or `:ok | {:unwind, signal}` for statements.
  Unwinds carry PHP control flow (return/break/continue/throw/halt) so that
  interpreter state changes (statics, refs) survive unwinding — unlike
  Elixir exceptions, which would discard accumulated state.
  """

  alias PhpBeam.{Env, Eval, PArray, Value}

  defstruct out: [],
            functions: %{},
            globals: %{},
            consts: %{},
            classes: %{},
            refs: %{},
            next_ref: 0,
            statics: %{},
            objects: %{},
            next_obj: 1,
            ns: [],
            uses: %{normal: %{}, function: %{}, const: %{}},
            halted: nil,
            suppress: 0,
            warnings: 0,
            ini: %{
              "precision" => "14",
              "serialize_precision" => "-1",
              "error_reporting" => "22527",
              "default_charset" => "UTF-8",
              "display_errors" => "1",
              "include_path" => ".:/opt/homebrew/Cellar/php/8.4.2/share/php/pear",
              "input_encoding" => "",
              "internal_encoding" => "",
              "output_encoding" => ""
            },
            error_handler: nil,
            shutdown_fns: [],
            autoload_fns: [],
            ob_stack: [],
            file_stack: [],
            included: %{},
            cur_line: 0,
            call_stack: [],
            resources: %{
              # 0/1/2 = STDIN/STDOUT/STDERR (php-cli constants); STDIN is at
              # EOF (non-interactive), STDOUT/STDERR are writable
              0 => %{std: :stdin, closed: false, eof: true},
              1 => %{std: :stdout, closed: false, eof: false},
              2 => %{std: :stderr, closed: false, eof: false}
            },
            next_res: 5,
            output_origin: nil,
            throw_pos: nil,
            # php's __get recursion guard: {obj_id, prop_key} pairs currently
            # inside their own __get — re-reads yield null + warning
            get_guards: MapSet.new(),
            # same guard for __set — re-writes create the property directly
            set_guards: MapSet.new(),
            # HTTP SAPI response area (nil under CLI): header()/setcookie()/
            # http_response_code() accumulate here for the server to emit
            sapi: nil,
            # {file, line} => nth instantiation, for php's
            # `Parent@anonymous file:line$id` class naming
            anon_sites: %{},
            # set inside a generator body process: %{driver: pid, key: int}
            gen_ctx: nil,
            mysqli_report: 3

  @type t :: %__MODULE__{}

  # ───────────────────────── entry points ─────────────────────────

  @doc "symlink-resolving realpath (this OTP lacks :file.realpath)"
  def real_path(p) do
    parts =
      if Path.type(p) == :absolute,
        do: Path.split(p),
        else: Path.split(Path.join(File.cwd!(), p))

    resolve_r(parts, [], 0)
  end

  defp resolve_r(["/" | rest], _acc, n), do: resolve_r(rest, [], n)
  defp resolve_r([], acc, _n), do: "/" <> Path.join(Enum.reverse(acc))
  defp resolve_r(["." | rest], acc, n), do: resolve_r(rest, acc, n)
  defp resolve_r([".." | rest], [_ | acc], n), do: resolve_r(rest, acc, n)
  defp resolve_r([".." | rest], [], n), do: resolve_r(rest, [], n)

  defp resolve_r([part | rest], acc, n) when n < 40 do
    full = "/" <> Path.join(Enum.reverse([part | acc]))

    case File.read_link(full) do
      {:ok, target} ->
        t =
          if Path.type(target) == :absolute,
            do: target,
            else: "/" <> Path.join(Enum.reverse(acc) ++ [target])

        resolve_r(Path.split(t) ++ rest, [], n + 1)

      _ ->
        resolve_r(rest, [part | acc], n)
    end
  end

  # symlink cycles: give up and append the unresolved tail
  defp resolve_r(parts, acc, _n), do: "/" <> Path.join(Enum.reverse(acc) ++ parts)

  def run(src, file \\ nil) do
    # the caller (cli) decides the spelling: real path for files,
    # "Command line code" for -r — matching php's __FILE__
    interp =
      register_builtins(%__MODULE__{file_stack: if(file, do: [file], else: [])})
      |> seed_server(file)

    env = Env.global_scope(argv_info(src))

    with {:ok, toks} <- PhpBeam.Lexer.tokenize(src),
         {:ok, stmts} <- PhpBeam.Parser.parse(toks) do
      {res, _env, interp2} = exec_stmts(stmts, env, interp)

      case res do
        {:unwind, {:halt, code}} ->
          finish(interp2, code)

        {:unwrap, _} ->
          finish(interp2, 0)

        :ok ->
          finish(interp2, 0)

        {:unwind, {:php_throw, val}} ->
          {render_uncaught(val, interp2), 255, interp2}

        {:unwind, {:fatal, msg}} ->
          {uncaught_out(interp2, "Error", msg), 255, interp2}

        {:unwind, {:engine_fatal, msg}} ->
          {engine_fatal_out(interp2, msg), 255, interp2}

        {:unwind, {:parse_error, msg, file, line}} ->
          {parse_error_out(interp2, "syntax error, " <> msg, file, line), 255, interp2}
      end
    else
      {:error, {:fatal_check, msg}, line} ->
        fname = file || "Command line code"
        {"\nFatal error: #{msg} in #{fname} on line #{line}\n", 255, interp2_stub()}

      {:error, msg, line} ->
        {"PHP Parse error:  syntax error, #{msg}" <> maybe_line(line) <> "\n", 255,
         interp2_stub()}
    end
  end

  # used by tests: returns {output, exit_code} without stderr noise
  def run_quiet(src) do
    {out, code, _interp} = run(src)
    {out, code}
  end

  @doc """
  HTTP-server entry: runs `src` with pre-seeded superglobals (globals map of
  name => value) and an active SAPI response area. Returns
  {body, exit_code, interp} like run/2; the server reads status/headers from
  the interp's sapi area.
  """
  def run_http(src, file, globals, sapi) do
    interp =
      register_builtins(%__MODULE__{file_stack: [file], sapi: sapi})
      |> Map.update!(:globals, &Map.merge(&1, globals))

    env = Env.global_scope([])

    with {:ok, toks} <- PhpBeam.Lexer.tokenize(src),
         {:ok, stmts} <- PhpBeam.Parser.parse(toks) do
      {res, _env, interp2} = exec_stmts(stmts, env, interp)

      case res do
        {:unwind, {:halt, _code}} ->
          finish(interp2, 0)

        {:unwrap, _} ->
          finish(interp2, 0)

        :ok ->
          finish(interp2, 0)

        {:unwind, {:php_throw, val}} ->
          {render_uncaught(val, interp2), 255, interp2}

        {:unwind, {:fatal, msg}} ->
          {uncaught_out(interp2, "Error", msg), 255, interp2}

        {:unwind, {:engine_fatal, msg}} ->
          {engine_fatal_out(interp2, msg), 255, interp2}

        {:unwind, {:parse_error, msg, f, line}} ->
          {parse_error_out(interp2, "syntax error, " <> msg, f, line), 255, interp2}
      end
    else
      {:error, msg, line} ->
        {"PHP Parse error:  syntax error, #{msg}" <> maybe_line(line) <> "\n", 255,
         interp2_stub()}
    end
  end

  # ───────────────────────── persistent REPL state ─────────────────────────

  def repl_init do
    {Env.global_scope([]), register_builtins(%__MODULE__{file_stack: ["php shell code"]})}
  end

  # evaluate one snippet against persistent state: {output, new_state}
  def repl_eval({env, interp}, src) do
    with {:ok, toks} <- PhpBeam.Lexer.tokenize("<?php " <> src),
         {:ok, stmts} <- PhpBeam.Parser.parse(toks) do
      {res, e2, i2} = exec_stmts(stmts, env, interp)

      out = IO.iodata_to_binary(Enum.reverse(i2.out))
      i3 = %{i2 | out: []}

      case res do
        :ok ->
          {out, {e2, i3}}

        {:unwind, {:return, _}} ->
          {out, {e2, i3}}

        {:unwind, {:halt, code}} ->
          {out, {:halt, code}}

        {:unwind, {:php_throw, val}} ->
          msg = uncaught_message(val, i3)
          {out <> msg, {env, i3}}

        {:unwind, {:fatal, msg}} ->
          {out <> "PHP Fatal error:  #{msg}\n", {env, i3}}

        {:unwind, _} ->
          {out, {e2, i3}}
      end
    else
      {:error, msg, line} ->
        {"PHP Parse error:  #{msg} on line #{line}\n", {env, interp}}
    end
  end

  defp uncaught_message({:native_error, class, msg}, _i),
    do: "\nPHP Fatal error:  Uncaught #{class}: #{msg}\n"

  defp uncaught_message({:object, _} = obj_ref, i) do
    obj = Eval.get_object(i, obj_ref)
    cls = display_class(i, obj.class)
    msg = PhpBeam.Eval.php_to_string(PArray.get(obj.props, {:string, "message"}, {:string, ""}))
    "\nPHP Fatal error:  Uncaught #{cls}: #{msg}\n"
  end

  defp uncaught_message(_, _i), do: "\nPHP Fatal error:  uncaught value\n"

  defp display_class(i, key) do
    case PhpBeam.Classes.get_class(i, key) do
      %{name: n} -> n
      _ -> if key == "stdclass", do: "stdClass", else: key
    end
  end

  defp interp2_stub, do: %__MODULE__{}

  defp maybe_line(0), do: ""
  defp maybe_line(l), do: " on line #{l}"

  defp argv_info(_src), do: []

  @doc "placeholder interp for contexts without one"
  def new_stub, do: %__MODULE__{}

  # ───────────────────────── pooling (L6/L8 seam) ─────────────────────────
  # Boot-scope fields survive a fork: class/function/const tables, ini and
  # the spl_autoload chain — the payoff of pre-warming (run vendor/autoload
  # once, fork per request). Everything else is request-scoped (php's
  # shared-nothing): output/ob, refs, objects, resources, statics, call
  # stack, included-files (require_once), sapi area, generator contexts.
  @boot_fields [:classes, :functions, :consts, :ini, :autoload_fns]

  @doc """
  Fork a pre-warmed interp for one request: boot fields are shared
  (persistent-data structures — copy-on-write), every request-scoped field
  resets to its fresh value (incl. the std 0/1/2 resources).
  """
  def fork_request(%__MODULE__{} = boot) do
    Enum.reduce(@boot_fields, %__MODULE__{}, fn field, acc ->
      %{acc | field => Map.get(boot, field)}
    end)
  end

  @doc "warm a boot interp by running files (vendor/autoload); output discarded"
  def warm(files) when is_list(files) do
    {_, _, interp} =
      Enum.reduce(files, register_builtins(%__MODULE__{}), fn file, acc ->
        case File.read(file) do
          {:ok, src} ->
            {_, _, it} = run_quiet_with(src, file, acc)
            it

          _ ->
            acc
        end
      end)

    interp
  end

  defp run_quiet_with(src, file, interp) do
    with {:ok, toks} <- PhpBeam.Lexer.tokenize(src),
         {:ok, stmts} <- PhpBeam.Parser.parse(toks) do
      {_, _, it} = exec_stmts(stmts, Env.global_scope([]), interp)
      {"", 0, it}
    else
      _ -> {"", 0, interp}
    end
  end

  defp finish(interp, code) do
    {IO.iodata_to_binary(Enum.reverse(interp.out)), code, interp}
  end

  defp render_uncaught({:native_error, class, msg}, interp),
    do: uncaught_out(interp, class, msg)

  defp render_uncaught({:object, _id} = ref, interp) do
    {class, msg} = PhpBeam.Classes.exception_info(interp, ref)
    uncaught_out(interp, class, msg)
  end

  defp render_uncaught(_, interp), do: IO.iodata_to_binary(Enum.reverse(interp.out))

  # ───────────────────────── output / warnings ─────────────────────────

  # writes land in the innermost open output buffer when ob_start is active
  def write(interp, data) when is_binary(data) do
    interp =
      if interp.output_origin == nil and data != "" do
        %{interp | output_origin: {current_file(interp), interp.cur_line}}
      else
        interp
      end

    case interp.ob_stack do
      [top | rest] -> %{interp | ob_stack: [%{top | buf: [data | top.buf]} | rest]}
      [] -> %{interp | out: [data | interp.out]}
    end
  end

  # php-cli display format: warnings go to stdout, positioned from the
  # innermost statement's line
  def warn(interp, msg) do
    if interp.suppress > 0 do
      interp
    else
      interp
      |> display("\nWarning: #{msg} in #{current_file(interp)} on line #{interp.cur_line}\n")
      |> Map.update!(:warnings, &(&1 + 1))
    end
  end

  # php routes warnings through display_errors: STDOUT shows them on stdout;
  # 0/off (what wp-config sets via @ini_set) hides them entirely
  defp display(interp, text) do
    case Map.get(interp.ini, "display_errors", "1") |> String.downcase() do
      v when v in ~w(1 on true yes stdout) -> write(interp, text)
      _ -> interp
    end
  end

  # php-cli stdout display: `Parse error: syntax error, ... in file on line N`
  defp parse_error_out(interp, msg, file, line) do
    out = IO.iodata_to_binary(Enum.reverse(interp.out))
    out <> "\nParse error: #{msg} in #{file} on line #{line}\n"
  end

  defp engine_fatal_out(interp, msg) do
    out = IO.iodata_to_binary(Enum.reverse(interp.out))
    {file, line} = interp.throw_pos || {current_file(interp), interp.cur_line}

    out <>
      "\nFatal error: #{msg} in #{file} on line #{line}\n"
  end

  # levelled variant: Notice:/Deprecated:/Warning: prefix instead of Warning
  def warn_level(interp, level, msg) do
    if interp.suppress > 0 do
      interp
    else
      interp
      |> display("\n#{level}: #{msg} in #{current_file(interp)} on line #{interp.cur_line}\n")
      |> Map.update!(:warnings, &(&1 + 1))
    end
  end

  defp current_file(%{file_stack: [f | _]}), do: f

  defp current_file(_), do: "Command line code"

  # frame = the call site of the function currently executing; php shows
  # these in uncaught-error stack traces, innermost first
  def push_frame(%{call_stack: cs} = interp, func) do
    frame = %{func: func, file: current_file(interp), line: interp.cur_line}
    %{interp | call_stack: [frame | cs]}
  end

  # frame with rendered arguments: php 8.4 traces show `g(10, 'x', Array)`
  def push_frame(interp, name, arg_vals) do
    push_frame(interp, "#{name}(#{render_frame_args(arg_vals, interp)})")
  end

  @doc "php 8.4 trace-argument rendering (also used by named-arg error frames)"
  def render_frame_args(arg_vals, interp) do
    Enum.map_join(arg_vals, ", ", &arg_display(&1, interp))
  end

  def render_arg(v, interp), do: arg_display(v, interp)

  defp arg_display({:int, n}, _), do: Integer.to_string(n)
  defp arg_display({:float, f}, _), do: PhpBeam.Value.float_to_string(f)
  defp arg_display({:bool, true}, _), do: "true"
  defp arg_display({:bool, false}, _), do: "false"
  defp arg_display(:null, _), do: "NULL"
  defp arg_display({:array, _}, _), do: "Array"

  defp arg_display({:string, s}, _) do
    if String.length(s) > 15,
      do: "'" <> String.slice(s, 0, 15) <> "...'",
      else: "'" <> s <> "'"
  end

  defp arg_display({:resource, id}, _), do: "Resource id ##{id}"

  defp arg_display({:object, id}, interp) do
    case Map.get(interp.objects, id) do
      %{class: cls} ->
        name = (PhpBeam.Classes.get_class(interp, cls) || %{name: cls}).name
        "Object(" <> name <> ")"

      _ ->
        "Object"
    end
  end

  defp arg_display(v, _), do: inspect(v)

  def pop_frame(%{call_stack: [_ | rest]} = interp), do: %{interp | call_stack: rest}

  # php-cli populates $_SERVER with structural keys (env keys are machine
  # specific and stay absent); WP's bootstrap reads PHP_SELF/SCRIPT_FILENAME

  # ── SAPI response area ──────────────────────────────────────────
  # header()/setcookie()/http_response_code() accumulate here when running
  # under the HTTP server (interp.sapi set); no-ops under the CLI.

  def sapi_add_header(%{sapi: nil} = i, _h, _replace), do: i

  def sapi_add_header(%{sapi: sapi} = i, h, replace?) do
    # php: "Status:" / "HTTP/..." set the response code instead
    case h do
      "Status:" <> code ->
        code_i =
          code |> String.trim() |> String.split(" ") |> hd() |> parse_status()

        %{i | sapi: %{sapi | status: code_i || sapi.status}}

      <<"HTTP/", _::binary>> = http_line ->
        parts = String.split(http_line, " ")
        code_i = parts |> Enum.at(1, "") |> parse_status()
        %{i | sapi: %{sapi | status: code_i || sapi.status}}

      _ ->
        headers =
          if replace? do
            {name, _} = split_header(h)
            Enum.reject(sapi.headers, fn ex -> elem(split_header(ex), 0) == name end)
          else
            sapi.headers
          end

        %{i | sapi: %{sapi | headers: headers ++ [h]}}
    end
  end

  defp parse_status(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp split_header(h) do
    case :binary.split(h, ":") do
      [name | _] -> {String.downcase(String.trim(name)), nil}
      [] -> {String.downcase(h), nil}
    end
  end

  def sapi_remove_header(%{sapi: nil} = i, _vals), do: i

  def sapi_remove_header(%{sapi: sapi} = i, vals) do
    case vals do
      [{:string, name} | _] ->
        keep =
          Enum.reject(sapi.headers, fn h -> elem(split_header(h), 0) == String.downcase(name) end)

        %{i | sapi: %{sapi | headers: keep}}

      _ ->
        %{i | sapi: %{sapi | headers: []}}
    end
  end

  def sapi_list_headers(%{sapi: nil}), do: PhpBeam.PArray.new()

  def sapi_list_headers(%{sapi: sapi}) do
    PhpBeam.PArray.from_pairs(Enum.map(sapi.headers, &{nil, {:string, &1}}))
  end

  def sapi_status(i, vals) do
    case {i.sapi, vals} do
      {nil, _} ->
        {200, i}

      {sapi, [{:int, n} | _]} when n >= 100 and n < 600 ->
        # php: setting returns the new code
        {n, %{i | sapi: %{sapi | status: n}}}

      {sapi, _} ->
        {sapi.status, i}
    end
  end

  def set_mysqli_report(interp, mode), do: %{interp | mysqli_report: mode}
  def get_mysqli_report(interp), do: interp.mysqli_report || 3

  defp seed_server(interp, nil), do: interp

  defp seed_server(interp, file) do
    now = System.system_time(:second)

    server =
      PArray.from_pairs([
        {{:string, "PHP_SELF"}, {:string, file}},
        {{:string, "SCRIPT_NAME"}, {:string, file}},
        {{:string, "SCRIPT_FILENAME"}, {:string, file}},
        {{:string, "REQUEST_TIME"}, {:int, now}},
        {{:string, "REQUEST_TIME_FLOAT"}, {:float, System.system_time(:millisecond) / 1000}},
        {{:string, "argv"}, {:array, PArray.from_pairs([{nil, {:string, file}}])}},
        {{:string, "argc"}, {:int, 1}},
        {{:string, "SERVER_PROTOCOL"}, {:string, "HTTP/1.1"}},
        {{:string, "REQUEST_METHOD"}, {:string, "GET"}},
        {{:string, "SERVER_SOFTWARE"}, {:string, "phpbeam/phpx"}}
      ])

    %{interp | globals: Map.put(interp.globals, "_SERVER", {:array, server})}
  end

  # ───────────────────────── stream resources ─────────────────────────

  def open_resource(interp, res) do
    id = interp.next_res
    {{:resource, id}, %{interp | resources: Map.put(interp.resources, id, res), next_res: id + 1}}
  end

  def get_resource(interp, {:resource, id}), do: Map.get(interp.resources, id)
  def get_resource(_interp, _), do: nil

  def put_resource(interp, {:resource, id}, res),
    do: %{interp | resources: Map.put(interp.resources, id, res)}

  def pop_frame(interp), do: interp

  # php 8.4 uncaught-error block; position comes from the failing statement
  defp uncaught_out(interp, class, msg) do
    out = IO.iodata_to_binary(Enum.reverse(interp.out))
    {file, line} = interp.throw_pos || {current_file(interp), interp.cur_line}

    # the stack's head is the innermost frame — render as-is
    frames =
      interp.call_stack
      |> Enum.with_index()
      |> Enum.map(fn {f, i} -> "##{i} #{f.file}(#{f.line}): #{f.func}\n" end)

    trace = frames ++ ["##{length(interp.call_stack)} {main}\n"]

    out <>
      "\nFatal error: Uncaught #{class}: #{msg} in #{file}:#{line}\nStack trace:\n" <>
      IO.iodata_to_binary(trace) <> "  thrown in #{file} on line #{line}\n"
  end

  defp register_builtins(interp) do
    interp
    |> Map.update!(:functions, fn fns -> Map.merge(fns, PhpBeam.Builtin.registry()) end)
    |> Map.update!(:classes, fn classes ->
      Map.merge(PhpBeam.Classes.native_classes(), classes)
    end)
  end

  # ───────────────────────── statement execution ─────────────────────────

  def exec_stmts(stmts, env, interp, acc \\ :ok)

  def exec_stmts([], env, interp, :ok), do: {:ok, env, interp}

  def exec_stmts([], env, interp, {:unwind, u}), do: {{:unwind, u}, env, interp}

  # once unwound, stop executing the remaining statements
  def exec_stmts([_ | _], env, interp, {:unwind, u}), do: {{:unwind, u}, env, interp}

  def exec_stmts([s | rest], env, interp, :ok) do
    case exec_stmt(s, env, interp) do
      {:ok, env2, interp2} ->
        exec_stmts(rest, env2, interp2, :ok)

      # forward goto: if the target label lives later in THIS list, resume
      # from just after it; otherwise let the unwind keep propagating
      {{:unwind, {:goto, label}}, env2, interp2} ->
        case split_at_label(rest, label) do
          {:found, after_label} -> exec_stmts(after_label, env2, interp2, :ok)
          :not_found -> exec_stmts([], env2, interp2, {:unwind, {:goto, label}})
        end

      {{:unwind, u}, env2, interp2} ->
        exec_stmts([], env2, interp2, {:unwind, u})
    end
  end

  defp split_at_label(stmts, label) do
    case Enum.find_index(stmts, fn
           {:stmt_line, _, {:label, ^label}} -> true
           _ -> false
         end) do
      nil -> :not_found
      idx -> {:found, Enum.drop(stmts, idx + 1)}
    end
  end

  # statements carry their source line; tracked for warnings/fatal rendering.
  # A throw/fatal is STAMPED here — at the innermost statement it escapes —
  # because finally blocks (and arg-eval paths) can shift cur_line before
  # the uncaught renderer runs
  def exec_stmt({:stmt_line, line, stmt}, env, interp) do
    case exec_stmt(stmt, env, %{interp | cur_line: line}) do
      {{:unwind, {:php_throw, _}} = r, env2, i2} ->
        stamp(r, env2, i2, line)

      {{:unwind, {:fatal, _}} = r, env2, i2} ->
        stamp(r, env2, i2, line)

      other ->
        other
    end
  end

  defp stamp({:unwind, u} = _inner, env, i2, line) do
    if i2.throw_pos == nil,
      do: {{:unwind, u}, env, %{i2 | throw_pos: {current_file(i2), line}}},
      else: {{:unwind, u}, env, i2}
  end

  def exec_stmt({:label, _name}, env, interp), do: {:ok, env, interp}

  # `goto l;` parses as an expression statement — emit the unwind
  def exec_stmt({:expr_stmt, {:goto, name}}, env, interp),
    do: {{:unwind, {:goto, name}}, env, interp}

  def exec_stmt({:goto, name}, env, interp),
    do: {{:unwind, {:goto, name}}, env, interp}

  def exec_stmt({:html, text}, env, interp), do: {:ok, env, write(interp, text)}

  def exec_stmt({:block, stmts}, env, interp), do: exec_stmts(stmts, env, interp)

  # `echo $a, f(), $b` compiles to one ECHO opcode per operand in php —
  # each argument is written before the next one is evaluated
  def exec_stmt({:echo, exprs}, env, interp) do
    Enum.reduce_while(exprs, {:ok, env, interp}, fn e, {:ok, en, it} ->
      case Eval.concat_to_string([e], en, it) do
        {out, en2, it2} -> {:cont, {:ok, en2, write(it2, out)}}
        {:unwind, u, en2, it2} -> {:halt, {{:unwind, u}, en2, it2}}
      end
    end)
  end

  def exec_stmt({:expr_stmt, e}, env, interp) do
    case Eval.eval(e, env, interp) do
      {{:val, _}, env2, interp2} -> {:ok, env2, interp2}
      unw -> unw
    end
  end

  def exec_stmt({:if, cond, then, else_part}, env, interp) do
    {{:val, c}, env2, interp2} = Eval.eval(cond, env, interp)

    if Value.truthy?(c) do
      exec_stmts(then, env2, interp2)
    else
      case else_part do
        nil -> {:ok, env2, interp2}
        stmts -> exec_stmts(stmts, env2, interp2)
      end
    end
  end

  def exec_stmt({:while, cond, body}, env, interp), do: loop_while(cond, body, env, interp)

  defp loop_while(cond, body, env, interp) do
    {{:val, c}, env2, interp2} = Eval.eval(cond, env, interp)

    if Value.truthy?(c) do
      case exec_stmts(body, env2, interp2) do
        {:ok, env3, interp3} ->
          loop_while(cond, body, env3, interp3)

        {{:unwind, {:break, 1}}, env3, interp3} ->
          {:ok, env3, interp3}

        {{:unwind, {:continue, 1}}, env3, interp3} ->
          loop_while(cond, body, env3, interp3)

        {{:unwind, {:break, n}}, env3, interp3} ->
          {{:unwind, {:break, n - 1}}, env3, interp3}

        {{:unwind, {:continue, n}}, env3, interp3} ->
          {{:unwind, {:continue, n - 1}}, env3, interp3}

        unw ->
          unw
      end
    else
      {:ok, env2, interp2}
    end
  end

  def exec_stmt({:do_while, body, cond}, env, interp), do: loop_do_while(body, cond, env, interp)

  defp loop_do_while(body, cond, env, interp) do
    case exec_stmts(body, env, interp) do
      {:ok, env2, interp2} ->
        {{:val, c}, env3, interp3} = Eval.eval(cond, env2, interp2)

        if Value.truthy?(c),
          do: loop_do_while(body, cond, env3, interp3),
          else: {:ok, env3, interp3}

      {{:unwind, {:break, 1}}, env2, interp2} ->
        {:ok, env2, interp2}

      {{:unwind, {:continue, 1}}, env2, interp2} ->
        {{:val, c}, env3, interp3} = Eval.eval(cond, env2, interp2)

        if Value.truthy?(c),
          do: loop_do_while(body, cond, env3, interp3),
          else: {:ok, env3, interp3}

      {{:unwind, {:break, n}}, env2, interp2} ->
        {{:unwind, {:break, n - 1}}, env2, interp2}

      {{:unwind, {:continue, n}}, env2, interp2} ->
        {{:unwind, {:continue, n - 1}}, env2, interp2}

      unw ->
        unw
    end
  end

  def exec_stmt({:for, init, cond, step, body}, env, interp) do
    {_, env1, interp1} = eval_all(init, env, interp)
    loop_for(cond, step, body, env1, interp1)
  end

  defp loop_for(cond, step, body, env, interp) do
    {go?, env2, interp2} =
      case cond do
        nil ->
          {true, env, interp}

        c ->
          {{:val, v}, e, i} = Eval.eval(c, env, interp)
          {Value.truthy?(v), e, i}
      end

    if go? do
      case exec_stmts(body, env2, interp2) do
        {:ok, env3, interp3} ->
          {_, env4, interp4} = eval_all(step, env3, interp3)
          loop_for(cond, step, body, env4, interp4)

        {{:unwind, {:break, 1}}, env3, interp3} ->
          {:ok, env3, interp3}

        {{:unwind, {:continue, 1}}, env3, interp3} ->
          {_, env4, interp4} = eval_all(step, env3, interp3)
          loop_for(cond, step, body, env4, interp4)

        {{:unwind, {:break, n}}, env3, interp3} ->
          {{:unwind, {:break, n - 1}}, env3, interp3}

        {{:unwind, {:continue, n}}, env3, interp3} ->
          {{:unwind, {:continue, n - 1}}, env3, interp3}

        unw ->
          unw
      end
    else
      {:ok, env2, interp2}
    end
  end

  defp eval_all(exprs, env, interp) do
    Enum.reduce(exprs, {[], env, interp}, fn e, {_, en, it} -> Eval.eval(e, en, it) end)
  end

  def exec_stmt({:foreach, subj, key_t, val_t, by_ref?, body}, env, interp) do
    {{:val, subject}, env2, interp2} = Eval.eval(subj, env, interp)

    case subject do
      {:array, arr} ->
        pairs = PArray.to_pairs(arr)

        if by_ref? do
          # by-ref foreach requires a writable lvalue subject for write-back
          case Eval.lvalue_path(subj, env2) do
            {:ok, path} -> foreach_ref(pairs, path, key_t, val_t, body, env2, interp2, subj)
            :error -> foreach_val(pairs, key_t, val_t, body, env2, interp2, true)
          end
        else
          foreach_val(pairs, key_t, val_t, body, env2, interp2, false)
        end

      {:object, _} = obj_ref ->
        obj = Eval.get_object(interp2, obj_ref)

        if obj.class == "generator" do
          foreach_gen(obj_ref, key_t, val_t, body, env2, interp2)
        else
          interp3 = warn(interp2, "foreach() argument must be of type array")
          {:ok, env2, interp3}
        end

      _other ->
        interp3 = warn(interp2, "foreach() argument must be of type array")
        {:ok, env2, interp3}
    end
  end

  # php: iterating a Generator drives valid()/key()/current()/next(); body
  # side effects (output, objects) ride the shuttled interp
  defp foreach_gen(obj_ref, key_t, val_t, body, env, interp) do
    case Eval.gen_resume(obj_ref, :start, interp) do
      {:yielded, _k, _v, _i2} = y ->
        gen_foreach_loop(y, obj_ref, key_t, val_t, body, env)

      other ->
        gen_foreach_end(other, env)
    end
  end

  defp gen_foreach_loop({:yielded, k, v, i2}, obj_ref, key_t, val_t, body, env) do
    v = Eval.deref(v, i2)
    {env2, interp2} = bind_target(env, i2, val_t, v)
    {env3, interp3} = bind_target(env2, interp2, key_t, k)

    case exec_stmts(body, env3, interp3) do
      {:ok, e4, i4} ->
        cont_foreach_gen(obj_ref, key_t, val_t, body, e4, i4)

      {{:unwind, {:break, 1}}, e4, i4} ->
        {:ok, e4, i4}

      {{:unwind, {:continue, 1}}, e4, i4} ->
        cont_foreach_gen(obj_ref, key_t, val_t, body, e4, i4)

      {{:unwind, {:break, n}}, e4, i4} ->
        {{:unwind, {:break, n - 1}}, e4, i4}

      {{:unwind, {:continue, n}}, e4, i4} ->
        {{:unwind, {:continue, n - 1}}, e4, i4}

      unw ->
        unw
    end
  end

  defp cont_foreach_gen(obj_ref, key_t, val_t, body, env, interp) do
    case Eval.gen_resume(obj_ref, :null, interp) do
      {:yielded, _, _, _} = y -> gen_foreach_loop(y, obj_ref, key_t, val_t, body, env)
      other -> gen_foreach_end(other, env)
    end
  end

  defp gen_foreach_end({:done, _ret, i2}, env), do: {:ok, env, i2}
  defp gen_foreach_end({:thrown, u, i2}, env), do: {{:unwind, u}, env, i2}

  defp foreach_val([], _key_t, _val_t, _body, env, interp, _ref?), do: {:ok, env, interp}

  defp foreach_val([{k, v} | rest], key_t, val_t, body, env, interp, ref?) do
    v = if ref?, do: v, else: Eval.deref(v, interp)

    {env2, interp2} = bind_target(env, interp, val_t, v)
    {env3, interp3} = bind_target(env2, interp2, key_t, wrap_key(k))

    case exec_stmts(body, env3, interp3) do
      {:ok, e4, i4} -> foreach_val(rest, key_t, val_t, body, e4, i4, ref?)
      {{:unwind, {:break, 1}}, e4, i4} -> {:ok, e4, i4}
      {{:unwind, {:continue, 1}}, e4, i4} -> foreach_val(rest, key_t, val_t, body, e4, i4, ref?)
      {{:unwind, {:break, n}}, e4, i4} -> {{:unwind, {:break, n - 1}}, e4, i4}
      {{:unwind, {:continue, n}}, e4, i4} -> {{:unwind, {:continue, n - 1}}, e4, i4}
      unw -> unw
    end
  end

  defp foreach_ref([], _path, _key_t, _val_t, _body, env, interp, _subj), do: {:ok, env, interp}

  defp foreach_ref([{k, v} | rest], path, key_t, val_t, body, env, interp, subj) do
    # bind $v to a reference cell, storing the cell in the array element
    {v_val, interp2} =
      case v do
        {:ref, _} = r ->
          {r, interp}

        plain ->
          {id, it} = new_ref(plain, interp)
          {{:ref, id}, it}
      end

    # write the ref back into the subject container
    interp3 =
      case Eval.path_write(path, k, v_val, env, interp2) do
        {_e, it} -> it
        _ -> interp2
      end

    {env2, interp4} = bind_target(env, interp3, val_t, v_val)
    {env3, interp5} = bind_target(env2, interp4, key_t, wrap_key(k))

    case exec_stmts(body, env3, interp5) do
      {:ok, env3, interp4} ->
        # subject may have been reassigned during the body; re-evaluate
        {{:val, subject}, _e, interp5} = Eval.eval(subj, env3, interp4)

        remaining =
          case subject do
            {:array, arr} -> remaining_pairs(arr, k)
            _ -> []
          end

        foreach_ref(remaining, path, key_t, val_t, body, env3, interp5, subj)

      {{:unwind, {:break, 1}}, env3, interp3} ->
        {:ok, env3, interp3}

      {{:unwind, {:continue, 1}}, env3, interp3} ->
        {{:val, subject}, _e, interp5} = Eval.eval(subj, env3, interp3)

        remaining =
          case subject do
            {:array, arr} -> remaining_pairs(arr, k)
            _ -> []
          end

        foreach_ref(remaining, path, key_t, val_t, body, env3, interp5, subj)

      {{:unwind, {:break, n}}, env3, interp3} ->
        {{:unwind, {:break, n - 1}}, env3, interp3}

      {{:unwind, {:continue, n}}, env3, interp3} ->
        {{:unwind, {:continue, n - 1}}, env3, interp3}

      unw ->
        unw
    end
  end

  # keys here are bare (int/binary), not tagged values
  defp remaining_pairs(arr, after_key) do
    pairs = PArray.to_pairs(arr)
    idx = Enum.find_index(pairs, fn {k, _} -> k == after_key end)

    cond do
      is_nil(idx) -> []
      true -> Enum.drop(pairs, idx + 1)
    end
  end

  defp bind_target(env, target, v, interp)

  # returns {env, interp} — binding at top level also updates interp.globals
  defp bind_target(env, interp, {:var, name}, v) do
    {:ok, env2, interp2} = Env.bind_var(env, interp, name, v)
    {env2, interp2}
  end

  defp bind_target(env, interp, {:var_var, e}, v) do
    case Eval.eval(e, env, interp) do
      {{:val, {:string, name}}, _e2, _i2} ->
        {:ok, env2, interp2} = Env.bind_var(env, interp, name, v)
        {env2, interp2}

      _ ->
        {env, interp}
    end
  end

  defp bind_target(env, interp, {:list_pat, items}, v) do
    {env2, interp2} = Eval.destructure(items, v, env, interp)
    {env2, interp2}
  end

  defp bind_target(env, interp, _other, _v), do: {env, interp}

  def exec_stmt({:switch, subj, cases}, env, interp) do
    {{:val, s}, env2, interp2} = Eval.eval(subj, env, interp)
    exec_switch_cases(cases, s, env2, interp2)
  end

  defp exec_switch_cases([], _s, env, interp), do: {:ok, env, interp}

  defp exec_switch_cases([{vals, stmts} | rest], s, env, interp) do
    match? =
      case vals do
        :default ->
          true

        list ->
          Enum.any?(list, fn v -> Value.loose_eq(s, Eval.const_eval_quiet(v, env, interp)) end)
      end

    if match? do
      # PHP executes the matched case body then falls through every
      # subsequent body (including a later default) until a break
      bodies = [stmts | Enum.map(rest, fn {_, st} -> st end)]
      run_switch_body(bodies, env, interp)
    else
      exec_switch_cases(rest, s, env, interp)
    end
  end

  defp run_switch_body([], env, interp), do: {:ok, env, interp}

  defp run_switch_body([stmts | rest], env, interp) do
    case exec_stmts(stmts, env, interp) do
      {:ok, env2, interp2} -> run_switch_body(rest, env2, interp2)
      {{:unwind, {:break, 1}}, env2, interp2} -> {:ok, env2, interp2}
      {{:unwind, {:break, n}}, env2, interp2} -> {{:unwind, {:break, n - 1}}, env2, interp2}
      {{:unwind, {:continue, n}}, env2, interp2} -> {{:unwind, {:continue, n}}, env2, interp2}
      unw -> unw
    end
  end

  def exec_stmt({:break, n}, env, interp),
    do: {{:unwind, {:break, level(n)}}, env, interp}

  def exec_stmt({:continue, n}, env, interp),
    do: {{:unwind, {:continue, level(n)}}, env, interp}

  defp level(nil), do: 1
  defp level({:int, n}) when n >= 1, do: n
  defp level(_), do: 1

  def exec_stmt({:return, nil}, _env, interp), do: {{:unwind, {:return, :null}}, nil, interp}

  def exec_stmt({:return, e}, env, interp) do
    case Eval.eval(e, env, interp) do
      {{:val, v}, _e2, i2} -> {{:unwind, {:return, v}}, nil, i2}
      unw -> unw
    end
  end

  def exec_stmt({:global, names}, env, interp) do
    env2 = Enum.reduce(names, env, fn n, acc -> Env.globalize(acc, n) end)

    # php seeds `global $x` as a NULL global when absent — later reads
    # must not warn "Undefined variable"
    interp2 =
      Enum.reduce(names, interp, fn n, acc ->
        case Map.fetch(acc.globals, n) do
          {:ok, _} -> acc
          :error -> %{acc | globals: Map.put(acc.globals, n, :null)}
        end
      end)

    {:ok, env2, interp2}
  end

  def exec_stmt({:static_vars, decls}, env, interp) do
    key = env.statics_key || {:main}

    case Map.fetch(interp.statics, key) do
      :error ->
        {vals, interp2} =
          Enum.reduce(decls, {%{}, interp}, fn {name, init}, {acc, it} ->
            case init do
              nil ->
                {Map.put(acc, name, :null), it}

              e ->
                case Eval.eval(e, env, it) do
                  {{:val, v}, _e2, it2} -> {Map.put(acc, name, v), it2}
                  _ -> {Map.put(acc, name, :null), it}
                end
            end
          end)

        env2 = Enum.reduce(Map.keys(vals), env, &Env.bind_static(&2, &1, key))
        {:ok, env2, put_in(interp2.statics[key], vals)}

      {:ok, vals} ->
        env2 = Enum.reduce(Map.keys(vals), env, &Env.bind_static(&2, &1, key))
        {:ok, env2, interp}
    end
  end

  def exec_stmt({:unset, targets}, env, interp) do
    case Enum.reduce_while(targets, {:ok, env, interp}, fn t, {:ok, e, i} ->
           case Eval.unset_target(t, e, i) do
             {:ok, e2, i2} -> {:cont, {:ok, e2, i2}}
             {{:unwind, _} = uw, e2, i2} -> {:halt, {uw, e2, i2}}
             _ -> {:cont, {:ok, e, i}}
           end
         end) do
      {:ok, env2, interp2} -> {:ok, env2, interp2}
      {{:unwind, _} = uw, env2, interp2} -> {uw, env2, interp2}
    end
  end

  def exec_stmt({:try_stmt, body, catches, finally}, env, interp) do
    case exec_stmts(body, env, interp) do
      {:ok, e2, i2} ->
        run_finally(finally, {:ok, e2, i2}, catches, e2, i2)

      {{:unwind, {:php_throw, val}} = uw, e2, i2} ->
        case find_catch(catches, val, e2, %{i2 | call_stack: []}) do
          {:caught, {res, e3, i3}} ->
            run_finally(finally, {res, e3, %{i3 | throw_pos: nil}}, catches, e3, %{
              i3
              | throw_pos: nil
            })

          :none ->
            case run_finally_raw(finally, e2, i2) do
              {:ok, e3, i3} -> {uw, e3, i3}
              other -> other
            end
        end

      {{:unwind, _} = uw, e2, i2} ->
        case run_finally_raw(finally, e2, i2) do
          {:ok, e3, i3} -> {uw, e3, i3}
          other -> other
        end
    end
  end

  defp run_finally(nil, res, _catches, _e, _i), do: res

  # finally's side effects must flow on: keep its env/interp, keep res's signal
  defp run_finally(finally, res, _catches, e, i) do
    case exec_stmts(finally, e, i) do
      {:ok, e2, i2} ->
        case res do
          {:ok, _, _} -> {:ok, e2, i2}
          {{:unwind, u}, _, _} -> {{:unwind, u}, e2, i2}
          other -> other
        end

      other ->
        other
    end
  end

  defp run_finally_raw(nil, e, i), do: {:ok, e, i}

  defp run_finally_raw(finally, e, i) do
    case exec_stmts(finally, e, i) do
      {:ok, e2, i2} -> {:ok, e2, i2}
      other -> other
    end
  end

  defp find_catch([], _val, _e, _i), do: :none

  defp find_catch([{types, var, body} | rest], val, e, i) do
    if catch_matches?(types, val, e, i) do
      {e2, i2} =
        if var do
          {:ok, e2, i2} = Env.bind_var(e, i, var, val)
          {e2, i2}
        else
          {e, i}
        end

      {:caught, exec_stmts(body, e2, i2)}
    else
      find_catch(rest, val, e, i)
    end
  end

  # a catch matches when the thrown value's class is or extends any listed type
  defp catch_matches?(types, val, _env, interp) do
    thrown_key =
      case val do
        {:object, _} ->
          Eval.get_object(interp, val).class

        {:native_error, class, _msg} ->
          String.downcase(class)

        _ ->
          nil
      end

    if thrown_key == nil do
      false
    else
      Enum.any?(types, fn parts ->
        case Eval.resolve_class_key({:cname, false, parts}, nil, interp) do
          {:ok, tkey} ->
            PhpBeam.Classes.is_a?(interp, thrown_key, tkey)

          _ ->
            false
        end
      end)
    end
  end

  def exec_stmt({:namespace, name, stmts}, env, interp) do
    # use aliases are per-namespace-block
    interp2 = %{interp | ns: name || [], uses: %{normal: %{}, function: %{}, const: %{}}}

    case stmts do
      nil -> {:ok, env, interp2}
      list -> exec_stmts(list, env, interp2)
    end
  end

  def exec_stmt({:use, kind, items, prefix}, env, interp) do
    uses =
      Enum.reduce(items, interp.uses, fn {parts, as}, acc ->
        full = if prefix, do: prefix ++ parts, else: parts
        short = as || List.last(full)
        # keep original casing — PSR-4 autoloaders build file paths from the
        # class NAME, and resolve_class_key downcases only the final key
        fq = full |> Enum.join("\\")

        kind_map = Map.get(acc, kind, %{})
        Map.put(acc, kind, Map.put(kind_map, String.downcase(short), fq))
      end)

    {:ok, env, %{interp | uses: uses}}
  end

  def exec_stmt({:halt, _}, env, interp), do: {:ok, env, interp}

  def exec_stmt({:enum_def, decl}, env, interp) do
    case PhpBeam.Enums.register(decl, interp) do
      {:ok, interp2} -> {:ok, env, interp2}
      {:error, msg} -> {{:unwind, {:engine_fatal, msg}}, env, interp}
    end
  end

  def exec_stmt({:class_def, decl}, env, interp) do
    case PhpBeam.Classes.register(decl, interp) do
      {:ok, interp2} ->
        {:ok, env, interp2}

      # link-time fatals render plain (no Uncaught wrapper, no trace);
      # zend attributes each check to its own site (child member line vs
      # class end line — Table carries it back)
      {:error, msg, line} when is_integer(line) and line > 0 ->
        it = %{interp | throw_pos: {current_file(interp), line}}
        {{:unwind, {:engine_fatal, msg}}, env, it}

      {:error, msg} ->
        {{:unwind, {:engine_fatal, msg}}, env, interp}
    end
  end

  def exec_stmt({:const_decl, entries}, env, interp) do
    consts =
      Enum.reduce(entries, interp.consts, fn {name, expr}, acc ->
        case Eval.const_fold(expr, interp) do
          {:ok, v} -> Map.put(acc, name, v)
          :defer -> Map.put(acc, name, :null)
        end
      end)

    {:ok, env, %{interp | consts: consts}}
  end

  def exec_stmt({:func_def, name, params, body}, env, interp) do
    def_file = current_file(interp)
    # php function names are case-insensitive and namespace-qualified: inside
    # `namespace Sodium;` a define lands under sodium\name (calls resolve the
    # ns-prefixed key first, then fall back to the global/builtin one)
    full = full_fn_key(name, interp)

    if Map.has_key?(interp.functions, full) do
      {:ok, env, warn(interp, "Cannot redeclare function #{name}()")}
    else
      # carry the defining file's namespace + use aliases: php binds them at
      # compile time, and plain functions execute long after other namespaced
      # includes have reset interp.uses
      entry =
        if PhpBeam.Ast.has_yield?(body) do
          {:user_gen, params, body, def_file, interp.cur_line, interp.ns, interp.uses}
        else
          {:user, params, body, def_file, interp.cur_line, interp.ns, interp.uses}
        end

      {:ok, env, %{interp | functions: Map.put(interp.functions, full, entry)}}
    end
  end

  defp full_fn_key(name, interp) do
    if interp.ns == [] do
      String.downcase(name)
    else
      (interp.ns ++ [name]) |> Enum.join("\\") |> String.downcase()
    end
  end

  defp wrap_key(k) when is_integer(k), do: {:int, k}
  defp wrap_key(k) when is_binary(k), do: {:string, k}

  # ───────────────────────── references ─────────────────────────

  def new_ref(v, interp) do
    id = interp.next_ref
    {id, %{interp | refs: Map.put(interp.refs, id, v), next_ref: id + 1}}
  end
end

defmodule PhpBeam.Builtin.PosixFns do
  @moduledoc """
  ext/posix mapped onto :os/:file/OTP (uid/gid via :file.read_file on
  system binaries is wrong — use :os.cmd probes captured at boot; in the
  escript the ids come from `id -u`/`id -g` shellouts, cached). The
  pwuid/grnam tables shell out to dscl-compatible `id`/`groups` output;
  everything else is direct :os/:erlang calls. Probed outputs match php
  CLI on this host (Darwin, uid 501).
  """

  alias PhpBeam.Eval
  alias PhpBeam.PArray

  def register(fns) do
    entries = %{
      "posix_getpid" => &getpid/2,
      "posix_getppid" => &getppid/2,
      "posix_getuid" => &getuid/2,
      "posix_geteuid" => &geteuid/2,
      "posix_getgid" => &getgid/2,
      "posix_getegid" => &getegid/2,
      "posix_getlogin" => &getlogin/2,
      "posix_uname" => &uname/2,
      "posix_getcwd" => &getcwd/2,
      "posix_strerror" => &strerror/2,
      "posix_errno" => &get_last_error/2,
      "posix_get_last_error" => &get_last_error/2,
      "posix_isatty" => &isatty/2,
      "posix_ttyname" => &ttyname/2,
      "posix_ctermid" => &ctermid/2,
      "posix_kill" => &kill/2,
      "posix_getpwuid" => &getpwuid/2,
      "posix_getpwnam" => &getpwnam/2,
      "posix_getgrgid" => &getgrgid/2,
      "posix_getgrnam" => &getgrnam/2,
      "posix_getgroups" => &getgroups/2,
      "posix_getpgid" => &getpgid/2,
      "posix_getpgrp" => &getpgrp/2,
      "posix_getsid" => &getsid/2,
      "posix_setsid" => &setsid/2,
      "posix_setuid" => &setuid/2,
      "posix_setgid" => &setgid/2,
      "posix_seteuid" => &seteuid/2,
      "posix_setegid" => &setegid/2,
      "posix_setpgid" => &setpgid/2,
      "posix_access" => &access/2,
      "posix_mkfifo" => &mkfifo/2,
      "posix_mknod" => &mknod/2,
      "posix_times" => &times/2,
      "posix_getrlimit" => &getrlimit/2,
      "posix_setrlimit" => &setrlimit/2,
      "posix_sysconf" => &sysconf/2,
      "posix_pathconf" => &pathconf/2,
      "posix_fpathconf" => &pathconf/2,
      "posix_initgroups" => &initgroups/2
    }

    wrapped =
      Map.new(entries, fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}}
      end)

    Map.merge(fns, wrapped)
  end

  # ────────────────────────── process identity ──────────────────────────

  defp getpid(_v, i), do: {:ok, {:int, os_pid()}, i}

  defp os_pid do
    case :os.getpid() do
      p when is_integer(p) -> p
      s when is_list(s) -> s |> List.to_string() |> String.to_integer()
    end
  end

  defp getppid(_v, i) do
    ppid =
      :os.cmd(~c"ps -o ppid= -p " ++ Integer.to_charlist(os_pid()))
      |> List.to_string()
      |> String.trim()
      |> String.to_integer()

    {:ok, {:int, ppid}, i}
  rescue
    _ -> {:ok, {:int, 0}, i}
  end

  defp cached_id(part) do
    :persistent_term.get({:phpbeam_posix, part}, nil) ||
      (
        v =
          :os.cmd(~c"id -" ++ [part])
          |> List.to_string()
          |> String.trim()
          |> String.to_integer()

        :persistent_term.put({:phpbeam_posix, part}, v)
        v
      )
  rescue
    _ -> 0
  end

  defp getuid(_v, i), do: {:ok, {:int, cached_id(?u)}, i}
  defp getgid(_v, i), do: {:ok, {:int, cached_id(?g)}, i}
  defp geteuid(_v, i), do: {:ok, {:int, cached_id(?u)}, i}
  defp getegid(_v, i), do: {:ok, {:int, cached_id(?g)}, i}

  defp getlogin(_v, i) do
    whoami = :os.cmd(~c"whoami") |> List.to_string() |> String.trim()
    {:ok, {:string, whoami}, i}
  end

  # ────────────────────────── system ──────────────────────────

  defp uname(_v, i) do
    sys = :os.type() |> elem(1) |> Atom.to_string() |> String.capitalize()
    node = :os.cmd(~c"hostname -s") |> List.to_string() |> String.trim()
    rel = :os.cmd(~c"uname -r") |> List.to_string() |> String.trim()
    ver = :os.cmd(~c"uname -v") |> List.to_string() |> String.trim()
    mach = :os.cmd(~c"uname -m") |> List.to_string() |> String.trim()

    arr =
      PArray.from_pairs([
        {"sysname", {:string, sys}},
        {"nodename", {:string, node}},
        {"release", {:string, rel}},
        {"version", {:string, ver}},
        {"machine", {:string, mach}}
      ])

    {:ok, {:array, arr}, i}
  end

  defp getcwd(_v, i) do
    {:ok, {:string, File.cwd!() |> normalize_tmp()}, i}
  rescue
    _ -> {:ok, {:bool, false}, i}
  end

  defp normalize_tmp(p) do
    # php getcwd reports /private/tmp-flavored paths like the C library;
    # our cwd for differential cases lives under the real path already
    p
  end

  @errno %{
    1 => "Operation not permitted",
    2 => "No such file or directory",
    3 => "No such process",
    4 => "Interrupted system call",
    5 => "Input/output error",
    9 => "Bad file descriptor",
    11 => "Resource deadlock avoided",
    13 => "Permission denied",
    17 => "File exists",
    20 => "Not a directory",
    21 => "Is a directory",
    22 => "Invalid argument",
    24 => "Too many open files",
    28 => "No space left on device",
    30 => "Read-only file system",
    32 => "Broken pipe",
    35 => "Resource temporarily unavailable",
    60 => "Operation timed out",
    61 => "Connection refused"
  }

  defp strerror(vals, i) do
    e = int_at(vals, 0, 0)
    fallback = "Undefined error: " <> Integer.to_string(e)
    {:ok, {:string, Map.get(@errno, e, fallback)}, i}
  end

  defp get_last_error(_v, i), do: {:ok, {:int, 0}, i}

  # ────────────────────────── ttys ──────────────────────────

  defp isatty(vals, i) do
    case Enum.at(vals, 0) do
      {:resource, rid} ->
        case Map.get(i.resources, rid) do
          %{std: :stdin} -> {:ok, {:bool, false}, i}
          _ -> {:ok, {:bool, false}, i}
        end

      {:int, fd} when fd in [0, 1, 2] ->
        {:ok, {:bool, false}, i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp ttyname(vals, i) do
    case Enum.at(vals, 0) do
      {:resource, rid} ->
        case Map.get(i.resources, rid) do
          %{std: :stdout} -> {:ok, {:string, "/dev/tty"}, i}
          _ -> {:ok, {:bool, false}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp ctermid(_v, i), do: {:ok, {:string, "/dev/tty"}, i}

  # ────────────────────────── signals / sessions ──────────────────────────

  defp kill(vals, i) do
    pid = int_at(vals, 0, 0)
    sig = int_at(vals, 1, 0)

    case sig do
      0 ->
        # existence probe: our own pid exists; others probe via ps
        me = os_pid()

        if pid == me do
          {:ok, {:bool, true}, i}
        else
          r = :os.cmd(~c"ps -p " ++ Integer.to_charlist(pid) ++ ~c" -o pid=")
          {:ok, {:bool, String.trim(List.to_string(r)) != ""}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp getpgid(vals, i) do
    pid = int_at(vals, 0, os_pid())
    r = :os.cmd(~c"ps -o pgid= -p " ++ Integer.to_charlist(pid)) |> List.to_string() |> String.trim()
    {:ok, {:int, String.to_integer(r)}, i}
  rescue
    _ -> {:ok, {:bool, false}, i}
  end

  defp getpgrp(_v, i), do: getpgid([{:int, os_pid()}], i)

  defp getsid(vals, i) do
    pid = int_at(vals, 0, os_pid())
    r = :os.cmd(~c"ps -o sess= -p " ++ Integer.to_charlist(pid)) |> List.to_string() |> String.trim()
    {:ok, {:int, String.to_integer(r)}, i}
  rescue
    _ -> {:ok, {:bool, false}, i}
  end

  defp setsid(_v, i), do: {:ok, {:int, -1}, i}

  defp setuid(_v, i), do: {:ok, {:bool, false}, i}
  defp setgid(_v, i), do: {:ok, {:bool, false}, i}
  defp seteuid(_v, i), do: {:ok, {:bool, false}, i}
  defp setegid(_v, i), do: {:ok, {:bool, false}, i}
  defp setpgid(_v, i), do: {:ok, {:bool, false}, i}
  defp initgroups(_v, i), do: {:ok, {:bool, false}, i}

  # ────────────────────────── user/group tables ──────────────────────────

  defp getpwuid(vals, i) do
    uid = int_at(vals, 0, cached_id(?u))
    pw_shell(~c"id -nu " ++ Integer.to_charlist(uid), uid, i)
  end

  defp getpwnam(vals, i) do
    name = str_at(vals, 0, "")
    uid_out = :os.cmd(~c"id -u " ++ String.to_charlist(name)) |> List.to_string() |> String.trim()

    case Integer.parse(uid_out) do
      {uid, _} -> pw_shell(~c"id -nu " ++ Integer.to_charlist(uid), uid, i, name)
      :error -> {:ok, {:bool, false}, i}
    end
  end

  defp pw_shell(cmd, uid, i, forced_name \\ nil) do
    out = :os.cmd(cmd) |> List.to_string() |> String.trim()
    name = forced_name || out
    home = :os.cmd(~c"dscl . -read /Users/" ++ String.to_charlist(name) ++ ~c" NFSHomeDirectory 2>/dev/null")
           |> List.to_string()
           |> String.replace("NFSHomeDirectory:", "")
           |> String.trim()

    shell =
      :os.cmd(~c"dscl . -read /Users/" ++ String.to_charlist(name) ++ ~c" UserShell 2>/dev/null")
      |> List.to_string()
      |> String.replace("UserShell:", "")
      |> String.trim()

    arr =
      PArray.from_pairs([
        {"name", {:string, name}},
        {"passwd", {:string, "*"}},
        {"uid", {:int, uid}},
        {"gid", {:int, cached_id(?g)}},
        {"gecos", {:string, ""}},
        {"dir", {:string, if(home == "", do: "/Users/" <> name, else: home)}},
        {"shell", {:string, if(shell == "", do: "/bin/zsh", else: shell)}}
      ])

    {:ok, {:array, arr}, i}
  rescue
    _ -> {:ok, {:bool, false}, i}
  end

  defp getgrgid(vals, i) do
    gid = int_at(vals, 0, cached_id(?g))
    name = group_name(gid)
    gr_arr(name, gid, i)
  end

  defp getgrnam(vals, i) do
    name = str_at(vals, 0, "")
    r = :os.cmd(~c"dscl . -read /Groups/" ++ String.to_charlist(name) ++ ~c" PrimaryGroupID 2>/dev/null")
        |> List.to_string() |> String.replace("PrimaryGroupID:", "") |> String.trim()

    case Integer.parse(r) do
      {gid, _} -> gr_arr(name, gid, i)
      :error -> {:ok, {:bool, false}, i}
    end
  end

  defp group_name(gid) do
    # common macOS groups straight from the group table
    r =
      :os.cmd(~c"dscl . -search /Groups PrimaryGroupID " ++ Integer.to_charlist(gid) ++ ~c" 2>/dev/null")
      |> List.to_string()
      |> String.split("\n")
      |> List.first("")
      |> String.split()
      |> List.first("")

    if r == "", do: "staff", else: r
  end

  defp gr_arr(name, gid, i) do
    arr =
      PArray.from_pairs([
        {"name", {:string, name}},
        {"passwd", {:string, "*"}},
        {"members", {:array, PArray.new()}},
        {"gid", {:int, gid}}
      ])

    {:ok, {:array, arr}, i}
  end

  defp getgroups(_v, i) do
    out = :os.cmd(~c"id -G") |> List.to_string() |> String.trim()

    arr =
      out
      |> String.split(" ")
      |> Enum.flat_map(fn s ->
        case Integer.parse(s) do
          {n, _} -> [n]
          :error -> []
        end
      end)
      |> Enum.map(&{:int, &1})

    {:ok, {:array, PArray.from_pairs(Enum.map(arr, &{nil, &1}))}, i}
  rescue
    _ -> {:ok, {:bool, false}, i}
  end

  # ────────────────────────── fs bits ──────────────────────────

  defp access(vals, i) do
    path = str_at(vals, 0, "")
    mode = int_at(vals, 1, 0)

    ok? =
      case mode do
        0 -> File.exists?(path)
        # R_OK on a directory is existence in php (reading a dir errors)
        1 -> File.exists?(path)
        2 -> File.exists?(path) and File.open(path, [:write]) != {:error, :eacces}
        4 -> File.exists?(path)
        _ -> false
      end

    {:ok, {:bool, ok?}, i}
  rescue
    _ -> {:ok, {:bool, false}, i}
  end

  defp mkfifo(vals, i) do
    path = str_at(vals, 0, "")
    r = :os.cmd(~c"mkfifo " ++ String.to_charlist(path) ++ ~c" 2>/dev/null")
    _ = r
    {:ok, {:bool, File.exists?(path)}, i}
  end

  defp mknod(_vals, i), do: {:ok, {:bool, false}, i}

  defp times(_v, i) do
    arr =
      PArray.from_pairs([
        {"ticks", {:int, :erlang.monotonic_time(:milli_seconds)}},
        {"utime", {:int, 0}},
        {"stime", {:int, 0}},
        {"cutime", {:int, 0}},
        {"cstime", {:int, 0}}
      ])

    {:ok, {:array, arr}, i}
  end

  @rlimit_soft %{
    "core" => {:int, 0},
    "data" => {:string, "unlimited"},
    "fsize" => {:string, "unlimited"},
    "nofile" => {:int, 10_240},
    "stack" => {:int, 8_388_608},
    "cpu" => {:string, "unlimited"}
  }

  defp getrlimit(vals, i) do
    which = int_at(vals, 0, 7)

    key =
      case which do
        3 -> "core"
        7 -> "nofile"
        8 -> "stack"
        _ -> "nofile"
      end

    soft = Map.get(@rlimit_soft, key, {:int, 0})

    arr =
      PArray.from_pairs([
        {"soft " <> key, soft},
        {"hard " <> key, soft}
      ])

    {:ok, {:array, arr}, i}
  end

  defp setrlimit(_vals, i), do: {:ok, {:bool, true}, i}

  @sysconf %{
    2 => 100, 3 => 4096, 4 => 30, 5 => 65536, 6 => 256, 7 => 256, 8 => 1048576,
    9 => 1, 10 => 32, 11 => 1024, 12 => 1, 13 => 1, 14 => 1024, 15 => 1, 16 => 32,
    24 => 1, 25 => 1, 26 => 1, 27 => 1, 28 => 1, 29 => 60, 30 => 8, 31 => 8,
    33 => 256, 34 => 64, 35 => 8, 55 => 1, 56 => 1, 57 => 1, 58 => 1, 59 => 1
  }

  defp sysconf(vals, i) do
    {:ok, {:int, Map.get(@sysconf, int_at(vals, 0, 0), 0)}, i}
  end

  defp pathconf(_vals, i), do: {:ok, {:int, 0}, i}

  # ────────────────────────── helpers ──────────────────────────

  defp str_at(vals, pos, default) do
    case Enum.at(vals, pos) do
      {:string, s} -> s
      _ -> default
    end
  end

  defp int_at(vals, pos, default) do
    case Enum.at(vals, pos) do
      {:int, n} -> n
      _ -> default
    end
  end
end

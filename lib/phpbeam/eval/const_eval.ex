defmodule PhpBeam.Eval.ConstEval do
  @moduledoc """
  Compile-time constant evaluation: const_fold (static-expression folding),
  const_eval (class const entries), eval_const_expr, magic/builtin consts.
  Moved verbatim from Eval (P2c).
  """

  alias PhpBeam.Eval
  @int_min -9_223_372_036_854_775_808
  @int_max 9_223_372_036_854_775_807
  alias PhpBeam.{Env, Error, Interp, PArray, Pattern, Value}

  def const_eval_quiet(v, _env, _interp), do: eval_const_expr(v)

  def eval_const_expr({:int, n}), do: {:int, n}

  def eval_const_expr({:string, s}), do: {:string, s}

  # pure-text interpolated literal (the parser's normal string shape)
  def eval_const_expr({:interp, [text: s]}), do: {:string, s}
  def eval_const_expr({:interp, _}), do: :null

  def eval_const_expr({:bool, b}), do: {:bool, b}

  def eval_const_expr(:null), do: :null

  def eval_const_expr(_), do: :null

  # resolve a class-name AST to a storage key (downcased, no leading backslash)
  # class lookup with the registered spl autoloaders run on miss (php
  # triggers them for new/static calls/class_exists-with-autoload). Returns
  # {class_or_nil, interp} — the autoloaders' side effects (require files
  # registering classes) thread back.

  def const_fold(ast, interp), do: const_fold(ast, interp, nil)

  # folds in the declaring class's scope so self::CONST resolves; anything
  # that can't fold eagerly (forward refs, function calls) defers to the AST

  def const_fold(ast, interp, scope) do
    env = if scope, do: %Env{scope_class: scope, called_class: scope}, else: nil

    case Eval.eval(ast, env, interp) do
      {{:val, :null}, _, _} ->
        case ast do
          :null -> {:ok, :null}
          _ -> :defer
        end

      {{:val, v}, _, _} ->
        {:ok, v}

      _ ->
        :defer
    end
  rescue
    _ -> :defer
  end

  # lazy const-expr evaluation (deferred {:const_ast, ...} markers)

  def const_eval(ast, interp, decl_key) do
    env = %Env{scope_class: decl_key, called_class: decl_key}
    {ns0, uses0, i0} = push_class_scope(interp, decl_key)

    case Eval.eval(ast, env, i0) do
      {{:val, v}, _, i2} -> {v, pop_class_scope(i2, ns0, uses0)}
      {{:unwind, _}, _, i2} -> {:null, pop_class_scope(i2, ns0, uses0)}
    end
  end

  # php compiles each class with its declaring file's namespace + use
  # aliases; method/const evaluation runs under that scope

  def resolve_const(name, _fq, env, interp) do
    case magic_const(name, env, interp) do
      {:ok, _} = ok -> ok
      :error -> resolve_plain_const(name, interp)
    end
  end

  def resolve_plain_const(name, interp) do
    case Map.fetch(interp.consts, name) do
      {:ok, v} -> {:ok, v}
      :error -> builtin_const(name)
    end
  end

  # magic constants are case-insensitive and resolve per file (include)

  def magic_const(name, env, interp) do
    current =
      case interp.file_stack do
        [cur | _] -> cur
        [] -> "Command line code"
      end

    case String.upcase(name) do
      "__FILE__" -> {:ok, {:string, current}}
      "__DIR__" -> {:ok, {:string, Path.dirname(current)}}
      "__FUNCTION__" -> {:ok, {:string, env.function || ""}}
      "__LINE__" -> {:ok, {:int, interp.cur_line}}
      "__METHOD__" -> {:ok, {:string, method_name(env, interp)}}
      "__CLASS__" -> {:ok, {:string, class_name_of(env, interp)}}
      "__NAMESPACE__" -> {:ok, {:string, Enum.join(interp.ns, "\\")}}
      _ -> :error
    end
  end

  def builtin_const(name) do
    case name do
      "PHP_EOL" ->
        {:ok, {:string, "\n"}}

      "PHP_INT_MAX" ->
        {:ok, {:int, @int_max}}

      "PHP_INT_MIN" ->
        {:ok, {:int, @int_min}}

      "PHP_INT_SIZE" ->
        {:ok, {:int, 8}}

      "PHP_FLOAT_EPSILON" ->
        {:ok, {:float, :math.pow(2, -52)}}

      "PHP_FLOAT_MAX" ->
        {:ok, {:float, 1.7976931348623157e308}}

      "PHP_FLOAT_MIN" ->
        {:ok, {:float, 2.2250738585072014e-308}}

      "PHP_VERSION" ->
        {:ok, {:string, "8.4.17"}}

      "PHP_VERSION_ID" ->
        {:ok, {:int, 80_417}}

      "PHP_MAJOR_VERSION" ->
        {:ok, {:int, 8}}

      "PHP_MINOR_VERSION" ->
        {:ok, {:int, 4}}

      "PHP_RELEASE_VERSION" ->
        {:ok, {:int, 17}}

      "PHP_EXTRA_VERSION" ->
        {:ok, {:string, ""}}

      "PHP_ZTS" ->
        {:ok, {:bool, false}}

      "PHP_OS" ->
        {:ok, {:string, "Darwin"}}

      "PHP_FLOAT_DIG" ->
        {:ok, {:int, 15}}

      "PHP_MAXPATHLEN" ->
        {:ok, {:int, 1024}}

      "PHP_BINARY" ->
        {:ok, {:string, "/opt/homebrew/bin/php"}}

      "PHP_OS" ->
        {:ok, {:string, "Darwin"}}

      "PHP_OS_FAMILY" ->
        {:ok, {:string, "Darwin"}}

      "PHP_SAPI" ->
        {:ok, {:string, "cli"}}

      "PHP_DEBUG" ->
        {:ok, {:bool, false}}

      "PHP_WINDOWS_VERSION_MAJOR" ->
        {:ok, {:bool, false}}

      "M_PI" ->
        {:ok, {:float, :math.pi()}}

      "M_E" ->
        {:ok, {:float, :math.exp(1)}}

      "M_SQRT2" ->
        {:ok, {:float, :math.sqrt(2)}}

      "NAN" ->
        {:ok, {:float, :erlang.nan()}}

      "INF" ->
        {:ok,
         {:float, :erlang.float_to_binary(:erlang.list_to_float('1.0e308')) |> String.to_float()}}

      "FILTER_VALIDATE_INT" ->
        {:ok, {:int, 257}}

      "FILTER_VALIDATE_BOOL" ->
        {:ok, {:int, 258}}

      "FILTER_VALIDATE_FLOAT" ->
        {:ok, {:int, 259}}

      "FILTER_VALIDATE_URL" ->
        {:ok, {:int, 273}}

      "FILTER_VALIDATE_EMAIL" ->
        {:ok, {:int, 274}}

      "FILTER_VALIDATE_IP" ->
        {:ok, {:int, 275}}

      "FILTER_VALIDATE_DOMAIN" ->
        {:ok, {:int, 277}}

      "FILTER_VALIDATE_REGEXP" ->
        {:ok, {:int, 272}}

      "FILTER_SANITIZE_NUMBER_INT" ->
        {:ok, {:int, 519}}

      "FILTER_SANITIZE_NUMBER_FLOAT" ->
        {:ok, {:int, 520}}

      "FILTER_SANITIZE_STRING" ->
        {:ok, {:int, 513}}

      "FILTER_UNSAFE_RAW" ->
        {:ok, {:int, 516}}

      "FILTER_DEFAULT" ->
        {:ok, {:int, 516}}

      "INPUT_GET" ->
        {:ok, {:int, 1}}

      "INPUT_POST" ->
        {:ok, {:int, 0}}

      "INPUT_COOKIE" ->
        {:ok, {:int, 2}}

      "INPUT_ENV" ->
        {:ok, {:int, 4}}

      "INPUT_SERVER" ->
        {:ok, {:int, 5}}

      "FILTER_CALLBACK" ->
        {:ok, {:int, 1024}}
      "FILTER_FLAG_ALLOW_FRACTION" ->
        {:ok, {:int, 4096}}
      "FILTER_FLAG_ALLOW_HEX" ->
        {:ok, {:int, 2}}
      "FILTER_FLAG_ALLOW_OCTAL" ->
        {:ok, {:int, 1}}
      "FILTER_FLAG_ALLOW_SCIENTIFIC" ->
        {:ok, {:int, 16384}}
      "FILTER_FLAG_ALLOW_THOUSAND" ->
        {:ok, {:int, 8192}}
      "FILTER_FLAG_EMAIL_UNICODE" ->
        {:ok, {:int, 1048576}}
      "FILTER_FLAG_EMPTY_STRING_NULL" ->
        {:ok, {:int, 256}}
      "FILTER_FLAG_ENCODE_AMP" ->
        {:ok, {:int, 64}}
      "FILTER_FLAG_ENCODE_HIGH" ->
        {:ok, {:int, 32}}
      "FILTER_FLAG_ENCODE_LOW" ->
        {:ok, {:int, 16}}
      "FILTER_FLAG_GLOBAL_RANGE" ->
        {:ok, {:int, 268435456}}
      "FILTER_FLAG_HOSTNAME" ->
        {:ok, {:int, 1048576}}
      "FILTER_FLAG_IPV4" ->
        {:ok, {:int, 1048576}}
      "FILTER_FLAG_IPV6" ->
        {:ok, {:int, 2097152}}
      "FILTER_FLAG_NONE" ->
        {:ok, {:int, 0}}
      "FILTER_FLAG_NO_ENCODE_QUOTES" ->
        {:ok, {:int, 128}}
      "FILTER_FLAG_NO_PRIV_RANGE" ->
        {:ok, {:int, 8388608}}
      "FILTER_FLAG_NO_RES_RANGE" ->
        {:ok, {:int, 4194304}}
      "FILTER_FLAG_PATH_REQUIRED" ->
        {:ok, {:int, 262144}}
      "FILTER_FLAG_QUERY_REQUIRED" ->
        {:ok, {:int, 524288}}
      "FILTER_FLAG_STRIP_BACKTICK" ->
        {:ok, {:int, 512}}
      "FILTER_FLAG_STRIP_HIGH" ->
        {:ok, {:int, 8}}
      "FILTER_FLAG_STRIP_LOW" ->
        {:ok, {:int, 4}}
      "FILTER_FORCE_ARRAY" ->
        {:ok, {:int, 67108864}}
      "FILTER_NULL_ON_FAILURE" ->
        {:ok, {:int, 134217728}}
      "FILTER_REQUIRE_ARRAY" ->
        {:ok, {:int, 16777216}}
      "FILTER_REQUIRE_SCALAR" ->
        {:ok, {:int, 33554432}}
      "FILTER_SANITIZE_ADD_SLASHES" ->
        {:ok, {:int, 523}}
      "FILTER_SANITIZE_EMAIL" ->
        {:ok, {:int, 517}}
      "FILTER_SANITIZE_ENCODED" ->
        {:ok, {:int, 514}}
      "FILTER_SANITIZE_FULL_SPECIAL_CHARS" ->
        {:ok, {:int, 522}}
      "FILTER_SANITIZE_SPECIAL_CHARS" ->
        {:ok, {:int, 515}}
      "FILTER_SANITIZE_STRIPPED" ->
        {:ok, {:int, 513}}
      "FILTER_SANITIZE_URL" ->
        {:ok, {:int, 518}}
      "FILTER_VALIDATE_BOOLEAN" ->
        {:ok, {:int, 258}}
      "FILTER_VALIDATE_MAC" ->
        {:ok, {:int, 276}}
      "INPUT_ENV" ->
        {:ok, {:int, 4}}
      "INPUT_SERVER" ->
        {:ok, {:int, 5}}

      "INPUT_ENV" ->
        {:ok, {:int, 5}}

      "PHP_SESSION_NONE" ->
        {:ok, {:int, 1}}

      "PHP_SESSION_ACTIVE" ->
        {:ok, {:int, 2}}

      "T_ABSTRACT" ->
        {:ok, {:int, 322}}

      "T_ARRAY" ->
        {:ok, {:int, 344}}

      "T_AS" ->
        {:ok, {:int, 301}}

      "T_BAD_CHARACTER" ->
        {:ok, {:int, 409}}

      "T_BOOLEAN_AND" ->
        {:ok, {:int, 369}}

      "T_BOOLEAN_OR" ->
        {:ok, {:int, 368}}

      "T_BREAK" ->
        {:ok, {:int, 307}}

      "T_CALLABLE" ->
        {:ok, {:int, 345}}

      "T_CASE" ->
        {:ok, {:int, 304}}

      "T_CATCH" ->
        {:ok, {:int, 315}}

      "T_CLASS" ->
        {:ok, {:int, 336}}

      "T_CLONE" ->
        {:ok, {:int, 285}}

      "T_CLOSE_TAG" ->
        {:ok, {:int, 395}}

      "T_COALESCE" ->
        {:ok, {:int, 404}}

      "T_COMMENT" ->
        {:ok, {:int, 391}}

      "T_CONST" ->
        {:ok, {:int, 312}}

      "T_CONSTANT_ENCAPSED_STRING" ->
        {:ok, {:int, 269}}

      "T_CONTINUE" ->
        {:ok, {:int, 308}}

      "T_CURLY_OPEN" ->
        {:ok, {:int, 400}}

      "T_DEC" ->
        {:ok, {:int, 380}}

      "T_DECLARE" ->
        {:ok, {:int, 299}}

      "T_DEFAULT" ->
        {:ok, {:int, 305}}

      "T_DNUMBER" ->
        {:ok, {:int, 261}}

      "T_DO" ->
        {:ok, {:int, 292}}

      "T_DOUBLE_ARROW" ->
        {:ok, {:int, 390}}

      "T_DOUBLE_COLON" ->
        {:ok, {:int, 401}}


      "FORCE_GZIP" ->
        {:ok, {:int, 31}}

      "FORCE_DEFLATE" ->
        {:ok, {:int, 15}}

      "ZLIB_ENCODING_RAW" ->
        {:ok, {:int, -15}}

      "ZLIB_ENCODING_GZIP" ->
        {:ok, {:int, 31}}

      "ZLIB_ENCODING_DEFLATE" ->
        {:ok, {:int, 15}}

      "ZLIB_NO_FLUSH" ->
        {:ok, {:int, 0}}

      "ZLIB_PARTIAL_FLUSH" ->
        {:ok, {:int, 1}}

      "ZLIB_SYNC_FLUSH" ->
        {:ok, {:int, 2}}

      "ZLIB_FULL_FLUSH" ->
        {:ok, {:int, 3}}

      "ZLIB_BLOCK" ->
        {:ok, {:int, 5}}

      "ZLIB_FINISH" ->
        {:ok, {:int, 4}}

      "ZLIB_FILTERED" ->
        {:ok, {:int, 1}}

      "ZLIB_HUFFMAN_ONLY" ->
        {:ok, {:int, 2}}

      "ZLIB_RLE" ->
        {:ok, {:int, 3}}

      "ZLIB_FIXED" ->
        {:ok, {:int, 4}}

      "ZLIB_DEFAULT_STRATEGY" ->
        {:ok, {:int, 0}}

      "ZLIB_VERNUM" ->
        {:ok, {:int, 4800}}



      "AF_UNIX" ->
        {:ok, {:int, 1}}


      "SQLITE3_OK" ->
        {:ok, {:int, 0}}

      "SQLITE3_ASSOC" ->
        {:ok, {:int, 1}}

      "SQLITE3_NUM" ->
        {:ok, {:int, 2}}

      "SQLITE3_BOTH" ->
        {:ok, {:int, 4}}

      "SQLITE3_INTEGER" ->
        {:ok, {:int, 1}}

      "SQLITE3_FLOAT" ->
        {:ok, {:int, 2}}

      "SQLITE3_TEXT" ->
        {:ok, {:int, 3}}

      "SQLITE3_BLOB" ->
        {:ok, {:int, 4}}

      "SQLITE3_NULL" ->
        {:ok, {:int, 5}}

      "SQLITE3_OPEN_READONLY" ->
        {:ok, {:int, 1}}

      "SQLITE3_OPEN_READWRITE" ->
        {:ok, {:int, 2}}

      "SQLITE3_OPEN_CREATE" ->
        {:ok, {:int, 4}}

      "AF_INET" ->
        {:ok, {:int, 2}}

      "AF_INET6" ->
        {:ok, {:int, 30}}

      "SOCK_STREAM" ->
        {:ok, {:int, 1}}

      "SOCK_DGRAM" ->
        {:ok, {:int, 2}}

      "SOCK_RAW" ->
        {:ok, {:int, 3}}

      "SOCK_SEQPACKET" ->
        {:ok, {:int, 5}}

      "SOCK_RDM" ->
        {:ok, {:int, 4}}

      "MSG_OOB" ->
        {:ok, {:int, 1}}

      "MSG_WAITALL" ->
        {:ok, {:int, 64}}

      "MSG_CTRUNC" ->
        {:ok, {:int, 32}}

      "MSG_TRUNC" ->
        {:ok, {:int, 16}}

      "MSG_PEEK" ->
        {:ok, {:int, 2}}

      "MSG_DONTROUTE" ->
        {:ok, {:int, 4}}

      "MSG_EOR" ->
        {:ok, {:int, 8}}

      "MSG_EOF" ->
        {:ok, {:int, 256}}

      "MSG_NOSIGNAL" ->
        {:ok, {:int, 524288}}

      "MSG_DONTWAIT" ->
        {:ok, {:int, 128}}

      "SO_DEBUG" ->
        {:ok, {:int, 1}}

      "SO_REUSEADDR" ->
        {:ok, {:int, 4}}

      "SO_REUSEPORT" ->
        {:ok, {:int, 512}}

      "SO_KEEPALIVE" ->
        {:ok, {:int, 8}}

      "SO_DONTROUTE" ->
        {:ok, {:int, 16}}

      "SO_LINGER" ->
        {:ok, {:int, 128}}

      "SO_LINGER_SEC" ->
        {:ok, {:int, 4224}}

      "SO_BROADCAST" ->
        {:ok, {:int, 32}}

      "SO_OOBINLINE" ->
        {:ok, {:int, 256}}

      "SO_SNDBUF" ->
        {:ok, {:int, 4097}}

      "SO_RCVBUF" ->
        {:ok, {:int, 4098}}

      "SO_SNDLOWAT" ->
        {:ok, {:int, 4099}}

      "SO_RCVLOWAT" ->
        {:ok, {:int, 4100}}

      "SO_SNDTIMEO" ->
        {:ok, {:int, 4101}}

      "SO_RCVTIMEO" ->
        {:ok, {:int, 4102}}

      "SO_TYPE" ->
        {:ok, {:int, 4104}}

      "SO_ERROR" ->
        {:ok, {:int, 4103}}

      "SO_BINDTODEVICE" ->
        {:ok, {:int, 4404}}

      "SO_DONTTRUNC" ->
        {:ok, {:int, 8192}}

      "SO_WANTMORE" ->
        {:ok, {:int, 16384}}

      "SOL_SOCKET" ->
        {:ok, {:int, 65535}}

      "SOMAXCONN" ->
        {:ok, {:int, 128}}

      "TCP_NODELAY" ->
        {:ok, {:int, 1}}

      "TCP_NOTSENT_LOWAT" ->
        {:ok, {:int, 513}}

      "TCP_KEEPALIVE" ->
        {:ok, {:int, 16}}

      "PHP_NORMAL_READ" ->
        {:ok, {:int, 1}}

      "PHP_BINARY_READ" ->
        {:ok, {:int, 2}}

      "MCAST_JOIN_GROUP" ->
        {:ok, {:int, 12}}

      "MCAST_LEAVE_GROUP" ->
        {:ok, {:int, 13}}

      "IP_MULTICAST_IF" ->
        {:ok, {:int, 9}}

      "IP_MULTICAST_TTL" ->
        {:ok, {:int, 10}}

      "IP_MULTICAST_LOOP" ->
        {:ok, {:int, 11}}

      "IPV6_MULTICAST_IF" ->
        {:ok, {:int, 9}}

      "IPV6_MULTICAST_HOPS" ->
        {:ok, {:int, 10}}

      "IPV6_MULTICAST_LOOP" ->
        {:ok, {:int, 11}}

      "IPV6_V6ONLY" ->
        {:ok, {:int, 27}}

      "IP_PORTRANGE" ->
        {:ok, {:int, 19}}

      "IP_PORTRANGE_DEFAULT" ->
        {:ok, {:int, 0}}

      "IP_PORTRANGE_HIGH" ->
        {:ok, {:int, 1}}

      "IP_PORTRANGE_LOW" ->
        {:ok, {:int, 2}}

      "SOCKET_EPERM" ->
        {:ok, {:int, 1}}

      "SOCKET_ENOENT" ->
        {:ok, {:int, 2}}

      "SOCKET_EINTR" ->
        {:ok, {:int, 4}}

      "SOCKET_EIO" ->
        {:ok, {:int, 5}}

      "SOCKET_ENXIO" ->
        {:ok, {:int, 6}}

      "SOCKET_E2BIG" ->
        {:ok, {:int, 7}}

      "SOCKET_EBADF" ->
        {:ok, {:int, 9}}

      "SOCKET_EAGAIN" ->
        {:ok, {:int, 35}}

      "SOCKET_ENOMEM" ->
        {:ok, {:int, 12}}

      "SOCKET_EACCES" ->
        {:ok, {:int, 13}}

      "SOCKET_EFAULT" ->
        {:ok, {:int, 14}}

      "SOCKET_ENOTBLK" ->
        {:ok, {:int, 15}}

      "SOCKET_EBUSY" ->
        {:ok, {:int, 16}}

      "SOCKET_EEXIST" ->
        {:ok, {:int, 17}}

      "SOCKET_EXDEV" ->
        {:ok, {:int, 18}}

      "SOCKET_ENODEV" ->
        {:ok, {:int, 19}}

      "SOCKET_ENOTDIR" ->
        {:ok, {:int, 20}}

      "SOCKET_EISDIR" ->
        {:ok, {:int, 21}}

      "SOCKET_EINVAL" ->
        {:ok, {:int, 22}}

      "SOCKET_ENFILE" ->
        {:ok, {:int, 23}}

      "SOCKET_EMFILE" ->
        {:ok, {:int, 24}}

      "SOCKET_ENOTTY" ->
        {:ok, {:int, 25}}

      "SOCKET_ENOSPC" ->
        {:ok, {:int, 28}}

      "SOCKET_ESPIPE" ->
        {:ok, {:int, 29}}

      "SOCKET_EROFS" ->
        {:ok, {:int, 30}}

      "SOCKET_EMLINK" ->
        {:ok, {:int, 31}}

      "SOCKET_EPIPE" ->
        {:ok, {:int, 32}}

      "SOCKET_ENAMETOOLONG" ->
        {:ok, {:int, 63}}

      "SOCKET_ENOLCK" ->
        {:ok, {:int, 77}}

      "SOCKET_ENOSYS" ->
        {:ok, {:int, 78}}

      "SOCKET_ENOTEMPTY" ->
        {:ok, {:int, 66}}

      "SOCKET_ELOOP" ->
        {:ok, {:int, 62}}

      "SOCKET_EWOULDBLOCK" ->
        {:ok, {:int, 35}}

      "SOCKET_ENOMSG" ->
        {:ok, {:int, 91}}

      "SOCKET_EIDRM" ->
        {:ok, {:int, 90}}

      "SOCKET_ENOSTR" ->
        {:ok, {:int, 99}}

      "SOCKET_ENODATA" ->
        {:ok, {:int, 96}}

      "SOCKET_ETIME" ->
        {:ok, {:int, 101}}

      "SOCKET_ENOSR" ->
        {:ok, {:int, 98}}

      "SOCKET_EREMOTE" ->
        {:ok, {:int, 71}}

      "SOCKET_ENOLINK" ->
        {:ok, {:int, 97}}

      "SOCKET_EPROTO" ->
        {:ok, {:int, 100}}

      "SOCKET_EMULTIHOP" ->
        {:ok, {:int, 95}}

      "SOCKET_EBADMSG" ->
        {:ok, {:int, 94}}

      "SOCKET_EUSERS" ->
        {:ok, {:int, 68}}

      "SOCKET_ENOTSOCK" ->
        {:ok, {:int, 38}}

      "SOCKET_EDESTADDRREQ" ->
        {:ok, {:int, 39}}

      "SOCKET_EMSGSIZE" ->
        {:ok, {:int, 40}}

      "SOCKET_EPROTOTYPE" ->
        {:ok, {:int, 41}}

      "SOCKET_ENOPROTOOPT" ->
        {:ok, {:int, 42}}

      "SOCKET_EPROTONOSUPPORT" ->
        {:ok, {:int, 43}}

      "SOCKET_ESOCKTNOSUPPORT" ->
        {:ok, {:int, 44}}

      "SOCKET_EOPNOTSUPP" ->
        {:ok, {:int, 102}}

      "SOCKET_EPFNOSUPPORT" ->
        {:ok, {:int, 46}}

      "SOCKET_EAFNOSUPPORT" ->
        {:ok, {:int, 47}}

      "SOCKET_EADDRINUSE" ->
        {:ok, {:int, 48}}

      "SOCKET_EADDRNOTAVAIL" ->
        {:ok, {:int, 49}}

      "SOCKET_ENETDOWN" ->
        {:ok, {:int, 50}}

      "SOCKET_ENETUNREACH" ->
        {:ok, {:int, 51}}

      "SOCKET_ENETRESET" ->
        {:ok, {:int, 52}}

      "SOCKET_ECONNABORTED" ->
        {:ok, {:int, 53}}

      "SOCKET_ECONNRESET" ->
        {:ok, {:int, 54}}

      "SOCKET_ENOBUFS" ->
        {:ok, {:int, 55}}

      "SOCKET_EISCONN" ->
        {:ok, {:int, 56}}

      "SOCKET_ENOTCONN" ->
        {:ok, {:int, 57}}

      "SOCKET_ESHUTDOWN" ->
        {:ok, {:int, 58}}

      "SOCKET_ETOOMANYREFS" ->
        {:ok, {:int, 59}}

      "SOCKET_ETIMEDOUT" ->
        {:ok, {:int, 60}}

      "SOCKET_ECONNREFUSED" ->
        {:ok, {:int, 61}}

      "SOCKET_EHOSTDOWN" ->
        {:ok, {:int, 64}}

      "SOCKET_EHOSTUNREACH" ->
        {:ok, {:int, 65}}

      "SOCKET_EALREADY" ->
        {:ok, {:int, 37}}

      "SOCKET_EINPROGRESS" ->
        {:ok, {:int, 36}}

      "SOCKET_EDQUOT" ->
        {:ok, {:int, 69}}

      "IPPROTO_IP" ->
        {:ok, {:int, 0}}

      "IPPROTO_IPV6" ->
        {:ok, {:int, 41}}

      "SOL_TCP" ->
        {:ok, {:int, 6}}

      "SOL_UDP" ->
        {:ok, {:int, 17}}

      "IPV6_UNICAST_HOPS" ->
        {:ok, {:int, 4}}

      "AI_PASSIVE" ->
        {:ok, {:int, 1}}

      "AI_CANONNAME" ->
        {:ok, {:int, 2}}

      "AI_NUMERICHOST" ->
        {:ok, {:int, 4}}

      "AI_V4MAPPED" ->
        {:ok, {:int, 2048}}

      "AI_ALL" ->
        {:ok, {:int, 256}}

      "AI_ADDRCONFIG" ->
        {:ok, {:int, 1024}}

      "AI_NUMERICSERV" ->
        {:ok, {:int, 4096}}

      "SOL_LOCAL" ->
        {:ok, {:int, 0}}

      "IPV6_RECVPKTINFO" ->
        {:ok, {:int, 61}}

      "IPV6_PKTINFO" ->
        {:ok, {:int, 46}}

      "IPV6_RECVHOPLIMIT" ->
        {:ok, {:int, 37}}

      "IPV6_HOPLIMIT" ->
        {:ok, {:int, 47}}

      "IPV6_RECVTCLASS" ->
        {:ok, {:int, 35}}

      "IPV6_TCLASS" ->
        {:ok, {:int, 36}}

      "SCM_RIGHTS" ->
        {:ok, {:int, 1}}

      "SO_NOSIGPIPE" ->
        {:ok, {:int, 4130}}

      "IP_DONTFRAG" ->
        {:ok, {:int, 28}}

      "OPENSSL_RAW_DATA" ->
        {:ok, {:int, 1}}

      "OPENSSL_ZERO_PADDING" ->
        {:ok, {:int, 2}}

      "OPENSSL_DONT_ZERO_PAD_KEY" ->
        {:ok, {:int, 4}}

      "OPENSSL_PKCS1_PADDING" ->
        {:ok, {:int, 1}}

      "OPENSSL_NO_PADDING" ->
        {:ok, {:int, 3}}

      "OPENSSL_PKCS1_OAEP_PADDING" ->
        {:ok, {:int, 4}}

      "OPENSSL_KEYTYPE_RSA" ->
        {:ok, {:int, 0}}

      "OPENSSL_KEYTYPE_DSA" ->
        {:ok, {:int, 1}}

      "OPENSSL_KEYTYPE_DH" ->
        {:ok, {:int, 2}}

      "OPENSSL_KEYTYPE_EC" ->
        {:ok, {:int, 3}}

      "OPENSSL_ALGO_SHA1" ->
        {:ok, {:int, 1}}

      "OPENSSL_ALGO_MD5" ->
        {:ok, {:int, 2}}

      "OPENSSL_ALGO_MD4" ->
        {:ok, {:int, 3}}

      "OPENSSL_ALGO_SHA224" ->
        {:ok, {:int, 6}}

      "OPENSSL_ALGO_SHA256" ->
        {:ok, {:int, 7}}

      "OPENSSL_ALGO_SHA384" ->
        {:ok, {:int, 8}}

      "OPENSSL_ALGO_SHA512" ->
        {:ok, {:int, 9}}

      "OPENSSL_ALGO_RMD160" ->
        {:ok, {:int, 10}}

      "OPENSSL_ENCODING_DER" ->
        {:ok, {:int, 0}}

      "OPENSSL_ENCODING_PEM" ->
        {:ok, {:int, 2}}

      "ZLIB_VERSION" ->
        {:ok, {:string, "1.2.12"}}

      "T_ECHO" ->
        {:ok, {:int, 291}}

      "T_ELSE" ->
        {:ok, {:int, 289}}

      "T_ELSEIF" ->
        {:ok, {:int, 288}}

      "T_EMPTY" ->
        {:ok, {:int, 334}}

      "T_ENDDECLARE" ->
        {:ok, {:int, 300}}

      "T_ENDFOR" ->
        {:ok, {:int, 296}}

      "T_ENDFOREACH" ->
        {:ok, {:int, 298}}

      "T_ENDIF" ->
        {:ok, {:int, 290}}

      "T_ENDSWITCH" ->
        {:ok, {:int, 303}}

      "T_ENDWHILE" ->
        {:ok, {:int, 294}}

      "T_ENUM" ->
        {:ok, {:int, 339}}

      "T_EXTENDS" ->
        {:ok, {:int, 340}}

      "T_FINAL" ->
        {:ok, {:int, 323}}

      "T_FINALLY" ->
        {:ok, {:int, 316}}

      "T_FN" ->
        {:ok, {:int, 311}}

      "T_FOR" ->
        {:ok, {:int, 295}}

      "T_FOREACH" ->
        {:ok, {:int, 297}}

      "T_FUNCTION" ->
        {:ok, {:int, 310}}

      "T_GLOBAL" ->
        {:ok, {:int, 320}}

      "T_GOTO" ->
        {:ok, {:int, 309}}

      "T_IF" ->
        {:ok, {:int, 287}}

      "T_IMPLEMENTS" ->
        {:ok, {:int, 341}}

      "T_INC" ->
        {:ok, {:int, 379}}

      "T_INCLUDE" ->
        {:ok, {:int, 272}}

      "T_INCLUDE_ONCE" ->
        {:ok, {:int, 273}}

      "T_INLINE_HTML" ->
        {:ok, {:int, 267}}

      "T_INSTANCEOF" ->
        {:ok, {:int, 283}}

      "T_INSTEADOF" ->
        {:ok, {:int, 319}}

      "T_INTERFACE" ->
        {:ok, {:int, 338}}

      "T_ISSET" ->
        {:ok, {:int, 333}}

      "T_IS_EQUAL" ->
        {:ok, {:int, 370}}

      "T_IS_GREATER_OR_EQUAL" ->
        {:ok, {:int, 375}}

      "T_IS_IDENTICAL" ->
        {:ok, {:int, 372}}

      "T_IS_NOT_EQUAL" ->
        {:ok, {:int, 371}}

      "T_IS_NOT_IDENTICAL" ->
        {:ok, {:int, 373}}

      "T_IS_SMALLER_OR_EQUAL" ->
        {:ok, {:int, 374}}

      "T_LIST" ->
        {:ok, {:int, 343}}

      "T_LNUMBER" ->
        {:ok, {:int, 260}}

      "T_LOGICAL_AND" ->
        {:ok, {:int, 279}}

      "T_LOGICAL_OR" ->
        {:ok, {:int, 277}}

      "T_LOGICAL_XOR" ->
        {:ok, {:int, 278}}

      "T_MATCH" ->
        {:ok, {:int, 306}}

      "T_NAMESPACE" ->
        {:ok, {:int, 342}}

      "T_NEW" ->
        {:ok, {:int, 284}}

      "T_NS_SEPARATOR" ->
        {:ok, {:int, 402}}

      "T_NULLSAFE_OBJECT_OPERATOR" ->
        {:ok, {:int, 389}}

      "T_NUM_STRING" ->
        {:ok, {:int, 271}}

      "T_OBJECT_OPERATOR" ->
        {:ok, {:int, 388}}

      "T_OPEN_TAG" ->
        {:ok, {:int, 393}}

      "T_OPEN_TAG_WITH_ECHO" ->
        {:ok, {:int, 394}}

      "T_PAAMAYIM_NEKUDOTAYIM" ->
        {:ok, {:int, 401}}

      "T_PRINT" ->
        {:ok, {:int, 280}}

      "T_PRIVATE" ->
        {:ok, {:int, 324}}

      "T_PROTECTED" ->
        {:ok, {:int, 325}}

      "T_PUBLIC" ->
        {:ok, {:int, 326}}

      "T_READONLY" ->
        {:ok, {:int, 330}}

      "T_RETURN" ->
        {:ok, {:int, 313}}

      "T_SL" ->
        {:ok, {:int, 377}}

      "T_SPACESHIP" ->
        {:ok, {:int, 376}}

      "T_SR" ->
        {:ok, {:int, 378}}

      "T_STATIC" ->
        {:ok, {:int, 321}}

      "T_STRING" ->
        {:ok, {:int, 262}}

      "T_SWITCH" ->
        {:ok, {:int, 302}}

      "T_THROW" ->
        {:ok, {:int, 317}}

      "T_TRAIT" ->
        {:ok, {:int, 337}}

      "T_TRY" ->
        {:ok, {:int, 314}}

      "T_UNSET" ->
        {:ok, {:int, 332}}

      "T_USE" ->
        {:ok, {:int, 318}}

      "T_VAR" ->
        {:ok, {:int, 331}}

      "T_VARIABLE" ->
        {:ok, {:int, 266}}

      "T_WHILE" ->
        {:ok, {:int, 293}}

      "T_WHITESPACE" ->
        {:ok, {:int, 396}}

      "T_YIELD" ->
        {:ok, {:int, 281}}

      "T_YIELD_FROM" ->
        {:ok, {:int, 282}}

      "E_ALL" ->
        # php 8.4: E_STRICT moved out of E_ALL (30719 = 32767 - 2048)
        {:ok, {:int, 30_719}}

      "E_WARNING" ->
        {:ok, {:int, 2}}

      "E_NOTICE" ->
        {:ok, {:int, 8}}

      "PHP_ZTS" ->
        {:ok, {:bool, false}}
        SHOULD_NOT_EXIST

      "STR_PAD_LEFT" ->
        {:ok, {:int, 0}}

      "STR_PAD_RIGHT" ->
        {:ok, {:int, 1}}

      "STR_PAD_BOTH" ->
        {:ok, {:int, 2}}

      "SORT_REGULAR" ->
        {:ok, {:int, 0}}

      "SORT_NUMERIC" ->
        {:ok, {:int, 1}}

      "SORT_STRING" ->
        {:ok, {:int, 2}}

      "COUNT_RECURSIVE" ->
        {:ok, {:int, 1}}

      "JSON_HEX_TAG" ->
        {:ok, {:int, 1}}

      "JSON_HEX_AMP" ->
        {:ok, {:int, 2}}

      "JSON_HEX_APOS" ->
        {:ok, {:int, 4}}

      "JSON_HEX_QUOT" ->
        {:ok, {:int, 8}}

      "JSON_FORCE_OBJECT" ->
        {:ok, {:int, 16}}

      "JSON_UNESCAPED_SLASHES" ->
        {:ok, {:int, 64}}

      "JSON_PRETTY_PRINT" ->
        {:ok, {:int, 128}}

      "JSON_UNESCAPED_UNICODE" ->
        {:ok, {:int, 256}}

      "JSON_PARTIAL_OUTPUT_ON_ERROR" ->
        {:ok, {:int, 512}}

      "JSON_INVALID_UTF8_SUBSTITUTE" ->
        {:ok, {:int, 2_097_152}}

      "JSON_THROW_ON_ERROR" ->
        {:ok, {:int, 4_194_304}}

      "EXTR_OVERWRITE" ->
        {:ok, {:int, 0}}

      "PHP_DEBUG" ->
        {:ok, {:bool, false}}

      "TRUE" ->
        {:ok, {:bool, true}}

      "FALSE" ->
        {:ok, {:bool, false}}

      "NULL" ->
        {:ok, :null}

      # error-reporting bit mask (PHP 8 values)
      "E_ERROR" ->
        {:ok, {:int, 1}}

      "E_RECOVERABLE_ERROR" ->
        {:ok, {:int, 4096}}

      "E_PARSE" ->
        {:ok, {:int, 4}}

      "E_CORE_ERROR" ->
        {:ok, {:int, 16}}

      "E_CORE_WARNING" ->
        {:ok, {:int, 32}}

      "E_COMPILE_ERROR" ->
        {:ok, {:int, 64}}

      "E_COMPILE_WARNING" ->
        {:ok, {:int, 128}}

      "E_USER_ERROR" ->
        {:ok, {:int, 256}}

      "E_USER_WARNING" ->
        {:ok, {:int, 512}}

      "E_USER_NOTICE" ->
        {:ok, {:int, 1024}}

      "E_USER_DEPRECATED" ->
        {:ok, {:int, 16_384}}

      "E_DEPRECATED" ->
        {:ok, {:int, 8192}}

      "E_STRICT" ->
        {:ok, {:int, 2048}}

      # setlocale categories (darwin C library values)
      "LC_CTYPE" ->
        {:ok, {:int, 0}}

      "LC_NUMERIC" ->
        {:ok, {:int, 1}}

      "LC_TIME" ->
        {:ok, {:int, 2}}

      "LC_COLLATE" ->
        {:ok, {:int, 3}}

      "LC_MONETARY" ->
        {:ok, {:int, 4}}

      "LC_MESSAGES" ->
        {:ok, {:int, 5}}

      "LC_ALL" ->
        {:ok, {:int, 6}}

      "DIRECTORY_SEPARATOR" ->
        {:ok, {:string, "/"}}

      "PATH_SEPARATOR" ->
        {:ok, {:string, ":"}}

      "FILE_APPEND" ->
        {:ok, {:int, 8}}

      "FILE_USE_INCLUDE_PATH" ->
        {:ok, {:int, 1}}

      "LOCK_EX" ->
        {:ok, {:int, 2}}

      "PREG_PATTERN_ORDER" ->
        {:ok, {:int, 1}}

      "PREG_SET_ORDER" ->
        {:ok, {:int, 2}}

      "PREG_SPLIT_NO_EMPTY" ->
        {:ok, {:int, 1}}

      "PREG_SPLIT_DELIM_CAPTURE" ->
        {:ok, {:int, 2}}

      "PREG_SPLIT_OFFSET_CAPTURE" ->
        {:ok, {:int, 4}}

      "PREG_OFFSET_CAPTURE" ->
        {:ok, {:int, 256}}

      "PREG_UNMATCHED_AS_NULL" ->
        {:ok, {:int, 512}}

      "PREG_GREP_INVERT" ->
        {:ok, {:int, 1}}

      "PREG_NO_ERROR" ->
        {:ok, {:int, 0}}

      "PHP_URL_SCHEME" ->
        {:ok, {:int, 0}}

      "PHP_URL_HOST" ->
        {:ok, {:int, 1}}

      "PHP_URL_PORT" ->
        {:ok, {:int, 2}}

      "PHP_URL_USER" ->
        {:ok, {:int, 3}}

      "PHP_URL_PASS" ->
        {:ok, {:int, 4}}

      "PHP_URL_PATH" ->
        {:ok, {:int, 5}}

      "PHP_URL_QUERY" ->
        {:ok, {:int, 6}}

      "PHP_URL_FRAGMENT" ->
        {:ok, {:int, 7}}

      "PATHINFO_DIRNAME" ->
        {:ok, {:int, 1}}

      "PATHINFO_BASENAME" ->
        {:ok, {:int, 2}}

      "PATHINFO_EXTENSION" ->
        {:ok, {:int, 4}}

      "PATHINFO_FILENAME" ->
        {:ok, {:int, 3}}

      "FILE_IGNORE_NEW_LINES" ->
        {:ok, {:int, 2}}

      "FILE_SKIP_EMPTY_LINES" ->
        {:ok, {:int, 4}}

      "EXTR_OVERWRITE" ->
        {:ok, {:int, 0}}

      "EXTR_SKIP" ->
        {:ok, {:int, 1}}

      "EXTR_PREFIX_SAME" ->
        {:ok, {:int, 2}}

      "EXTR_IF_EXISTS" ->
        {:ok, {:int, 6}}

      "PHP_QUERY_RFC1738" ->
        {:ok, {:int, 1738}}

      "PHP_QUERY_RFC3986" ->
        {:ok, {:int, 3986}}

      "JSON_ERROR_NONE" ->
        {:ok, {:int, 0}}

      "STDIN" ->
        {:ok, {:resource, 0}}

      "STDOUT" ->
        {:ok, {:resource, 1}}

      "STDERR" ->
        {:ok, {:resource, 2}}

      "SEEK_SET" ->
        {:ok, {:int, 0}}

      "SEEK_CUR" ->
        {:ok, {:int, 1}}

      "SEEK_END" ->
        {:ok, {:int, 2}}

      "LOCK_SH" ->
        {:ok, {:int, 1}}

      "LOCK_UN" ->
        {:ok, {:int, 3}}

      "MYSQLI_REPORT_OFF" ->
        {:ok, {:int, 0}}

      "ENT_COMPAT" ->
        {:ok, {:int, 2}}

      "ENT_QUOTES" ->
        {:ok, {:int, 3}}

      "ENT_NOQUOTES" ->
        {:ok, {:int, 0}}

      "ENT_IGNORE" ->
        {:ok, {:int, 4}}

      "ENT_SUBSTITUTE" ->
        {:ok, {:int, 8}}

      "ENT_HTML401" ->
        {:ok, {:int, 0}}

      "ENT_HTML5" ->
        {:ok, {:int, 48}}

      "CASE_UPPER" ->
        {:ok, {:int, 1}}

      "CASE_LOWER" ->
        {:ok, {:int, 0}}

      "MYSQLI_CLIENT_SSL" ->
        {:ok, {:int, 2048}}

      "MYSQLI_CLIENT_COMPRESS" ->
        {:ok, {:int, 32}}

      "MYSQLI_OPT_SSL_VERIFY_SERVER_CERT" ->
        {:ok, {:int, 2048}}

      "MYSQLI_REPORT_ERROR" ->
        {:ok, {:int, 1}}

      "MYSQLI_REPORT_STRICT" ->
        {:ok, {:int, 2}}

      "MYSQLI_REPORT_INDEX" ->
        {:ok, {:int, 4}}

      "MYSQLI_REPORT_ALL" ->
        {:ok, {:int, 255}}

      "MYSQLI_ASSOC" ->
        {:ok, {:int, 1}}

      "MYSQLI_NUM" ->
        {:ok, {:int, 2}}

      "MYSQLI_BOTH" ->
        {:ok, {:int, 3}}

      "MYSQLI_CLIENT_COMPRESS" ->
        {:ok, {:int, 32}}

      "MYSQLI_OPT_INT_AND_FLOAT_NATIVE" ->
        {:ok, {:int, 205}}

      "DATE_W3C" ->
        {:ok, {:string, "Y-m-d\\TH:i:sP"}}

      "DATE_ATOM" ->
        {:ok, {:string, "Y-m-d\\TH:i:sP"}}

      "DATE_ISO8601" ->
        {:ok, {:string, "Y-m-d\\TH:i:sO"}}

      "DATE_RFC2822" ->
        {:ok, {:string, "D, d M Y H:i:s O"}}

      "PREG_PATTERN_ORDER" ->
        {:ok, {:int, 1}}

      "PREG_SET_ORDER" ->
        {:ok, {:int, 2}}

      "PREG_SPLIT_NO_EMPTY" ->
        {:ok, {:int, 1}}

      "PREG_SPLIT_DELIM_CAPTURE" ->
        {:ok, {:int, 2}}

      "PREG_SPLIT_OFFSET_CAPTURE" ->
        {:ok, {:int, 4}}

      "PREG_OFFSET_CAPTURE" ->
        {:ok, {:int, 256}}

      "PREG_UNMATCHED_AS_NULL" ->
        {:ok, {:int, 512}}

      "PREG_GREP_INVERT" ->
        {:ok, {:int, 1}}

      "PREG_NO_ERROR" ->
        {:ok, {:int, 0}}

      _ ->
        case PhpBeam.Builtin.CurlConsts.lookup(name) do
          nil -> :error
          v -> {:ok, v}
        end
    end
  end

  defp class_key_of(a, b, c), do: Eval.class_key_of(a, b, c)
  defp static_prop_name(a, b, c), do: Eval.static_prop_name(a, b, c)
  defp static_props_key(a), do: Eval.static_props_key(a)
  defp make_instance(a, b), do: Eval.make_instance(a, b)
  defp call_php_method(a, b, c, d, e), do: Eval.call_php_method(a, b, c, d, e)
  defp materialize_native(a, b), do: Eval.materialize_native(a, b)
  defp class_name_of(a, b), do: Eval.class_name_of(a, b)
  defp pop_class_scope(a, b, c), do: Eval.pop_class_scope(a, b, c)

  defp push_class_scope(a, b), do: Eval.push_class_scope(a, b)
  defp method_name(a, b), do: Eval.method_name(a, b)
end

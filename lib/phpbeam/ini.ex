defmodule PhpBeam.Ini do
  @moduledoc """
  The INI layer: php 8.4's registered-entry table (access level + default
  value per entry, dumped from this machine's reference php 8.4.2 via
  `ini_get_all(null, true)`), the php.ini file parser, and
  `ini_parse_quantity` (a port of zend_ini.c's
  zend_ini_parse_quantity_internal — the multiplier is decided by the LAST
  character of the trimmed string, which is why "1_000" warns with
  multiplier "0").

  php.ini can only override REGISTERED entries — unknown names are ignored
  silently (probed: -c with x=1 then ini_get("x") is false). Access bits:
  USER=1, PERDIR=2, SYSTEM=4, ALL=7. Runtime ini_set needs USER;
  .user.ini needs PERDIR.

  V1 fidelity note: defaults are the homebrew-ini-loaded values (matching
  the differential oracle `php file`); `-n`/`-c` do not model
  extension-entry unloading.
  """

  import Bitwise

  # name => {module, access, default}
  @table %{
    "SMTP" => {"Core", 7, "localhost"},
    "allow_url_fopen" => {"Core", 4, "1"},
    "allow_url_include" => {"Core", 4, ""},
    "arg_separator.input" => {"arg_separator", 6, "&"},
    "arg_separator.output" => {"arg_separator", 7, "&"},
    "assert.active" => {"standard", 7, "1"},
    "assert.bail" => {"standard", 7, "0"},
    "assert.callback" => {"standard", 7, ""},
    "assert.exception" => {"standard", 7, "1"},
    "assert.warning" => {"standard", 7, "1"},
    "auto_append_file" => {"Core", 6, ""},
    "auto_detect_line_endings" => {"standard", 7, "0"},
    "auto_globals_jit" => {"Core", 6, "1"},
    "auto_prepend_file" => {"Core", 6, ""},
    "bcmath.scale" => {"bcmath", 7, "0"},
    "browscap" => {"Core", 4, ""},
    "cli.pager" => {"readline", 7, ""},
    "cli.prompt" => {"readline", 7, "\\\\b \\\\> "},
    "curl.cainfo" => {"curl", 4, ""},
    "date.default_latitude" => {"date", 7, "31.7667"},
    "date.default_longitude" => {"date", 7, "35.2333"},
    "date.sunrise_zenith" => {"date", 7, "90.833333"},
    "date.sunset_zenith" => {"date", 7, "90.833333"},
    "date.timezone" => {"date", 7, "UTC"},
    "dba.default_handler" => {"dba", 7, "flatfile"},
    "default_charset" => {"Core", 7, "UTF-8"},
    "default_mimetype" => {"Core", 7, "text/html"},
    "default_socket_timeout" => {"standard", 7, "60"},
    "disable_classes" => {"Core", 4, ""},
    "disable_functions" => {"Core", 4, ""},
    "display_errors" => {"Core", 7, "1"},
    "display_startup_errors" => {"Core", 7, "1"},
    "doc_root" => {"Core", 4, ""},
    "docref_ext" => {"Core", 7, ""},
    "docref_root" => {"Core", 7, ""},
    "enable_dl" => {"Core", 4, ""},
    "enable_post_data_reading" => {"Core", 6, "1"},
    "error_append_string" => {"Core", 7, ""},
    "error_log" => {"Core", 7, ""},
    "error_log_mode" => {"Core", 7, "0644"},
    "error_prepend_string" => {"Core", 7, ""},
    "error_reporting" => {"Core", 7, "30719"},
    "exif.decode_jis_intel" => {"exif", 7, "JIS"},
    "exif.decode_jis_motorola" => {"exif", 7, "JIS"},
    "exif.decode_unicode_intel" => {"exif", 7, "UCS-2LE"},
    "exif.decode_unicode_motorola" => {"exif", 7, "UCS-2BE"},
    "exif.encode_jis" => {"exif", 7, ""},
    "exif.encode_unicode" => {"exif", 7, "ISO-8859-15"},
    "expose_php" => {"Core", 4, "1"},
    "extension_dir" => {"Core", 4, "/opt/homebrew/lib/php/pecl/20240924"},
    "ffi.enable" => {"ffi", 4, "preload"},
    "ffi.preload" => {"ffi", 4, ""},
    "fiber.stack_size" => {"fiber", 7, ""},
    "file_uploads" => {"Core", 4, "1"},
    "filter.default" => {"filter", 6, "unsafe_raw"},
    "filter.default_flags" => {"filter", 6, ""},
    "from" => {"standard", 7, ""},
    "gd.jpeg_ignore_warning" => {"gd", 7, "1"},
    "hard_timeout" => {"Core", 4, "2"},
    "highlight.comment" => {"highlight", 7, "#FF8000"},
    "highlight.default" => {"highlight", 7, "#0000BB"},
    "highlight.html" => {"highlight", 7, "#000000"},
    "highlight.keyword" => {"highlight", 7, "#007700"},
    "highlight.string" => {"highlight", 7, "#DD0000"},
    "html_errors" => {"Core", 7, "0"},
    "iconv.input_encoding" => {"iconv", 7, ""},
    "iconv.internal_encoding" => {"iconv", 7, ""},
    "iconv.output_encoding" => {"iconv", 7, ""},
    "ignore_repeated_errors" => {"Core", 7, ""},
    "ignore_repeated_source" => {"Core", 7, ""},
    "ignore_user_abort" => {"Core", 7, "0"},
    "implicit_flush" => {"Core", 7, "1"},
    "include_path" => {"Core", 7, ".:/opt/homebrew/Cellar/php@8.4/8.4.17/share/php@8.4/pear"},
    "input_encoding" => {"Core", 7, ""},
    "internal_encoding" => {"Core", 7, ""},
    "intl.default_locale" => {"intl", 7, ""},
    "intl.error_level" => {"intl", 7, "0"},
    "intl.use_exceptions" => {"intl", 7, "0"},
    "ldap.max_links" => {"ldap", 4, "-1"},
    "log_errors" => {"Core", 7, "1"},
    "mail.add_x_header" => {"mail", 6, ""},
    "mail.force_extra_parameters" => {"mail", 6, ""},
    "mail.log" => {"mail", 6, ""},
    "mail.mixed_lf_and_crlf" => {"mail", 6, ""},
    "max_execution_time" => {"Core", 7, "0"},
    "max_file_uploads" => {"Core", 6, "20"},
    "max_input_nesting_level" => {"Core", 6, "64"},
    "max_input_time" => {"Core", 6, "-1"},
    "max_input_vars" => {"Core", 6, "1000"},
    "max_multipart_body_parts" => {"Core", 6, "-1"},
    "mbstring.detect_order" => {"mbstring", 7, ""},
    "mbstring.encoding_translation" => {"mbstring", 6, "0"},
    "mbstring.http_input" => {"mbstring", 7, ""},
    "mbstring.http_output" => {"mbstring", 7, ""},
    "mbstring.http_output_conv_mimetypes" =>
      {"mbstring", 7, "^(text/|application/xhtml\\\\+xml)"},
    "mbstring.internal_encoding" => {"mbstring", 7, ""},
    "mbstring.language" => {"mbstring", 7, "neutral"},
    "mbstring.regex_retry_limit" => {"mbstring", 7, "1000000"},
    "mbstring.regex_stack_limit" => {"mbstring", 7, "100000"},
    "mbstring.strict_detection" => {"mbstring", 7, "0"},
    "mbstring.substitute_character" => {"mbstring", 7, ""},
    "memory_limit" => {"Core", 7, "128M"},
    "mysqli.allow_local_infile" => {"mysqli", 4, "0"},
    "mysqli.allow_persistent" => {"mysqli", 4, "1"},
    "mysqli.default_host" => {"mysqli", 7, ""},
    "mysqli.default_port" => {"mysqli", 7, "3306"},
    "mysqli.default_pw" => {"mysqli", 7, ""},
    "mysqli.default_socket" => {"mysqli", 7, "/tmp/mysql.sock"},
    "mysqli.default_user" => {"mysqli", 7, ""},
    "mysqli.local_infile_directory" => {"mysqli", 4, ""},
    "mysqli.max_links" => {"mysqli", 4, "-1"},
    "mysqli.max_persistent" => {"mysqli", 4, "-1"},
    "mysqli.rollback_on_cached_plink" => {"mysqli", 4, "0"},
    "mysqlnd.collect_memory_statistics" => {"mysqlnd", 4, "1"},
    "mysqlnd.collect_statistics" => {"mysqlnd", 7, "1"},
    "mysqlnd.debug" => {"mysqlnd", 4, ""},
    "mysqlnd.log_mask" => {"mysqlnd", 7, "0"},
    "mysqlnd.mempool_default_size" => {"mysqlnd", 7, "16000"},
    "mysqlnd.net_cmd_buffer_size" => {"mysqlnd", 7, "4096"},
    "mysqlnd.net_read_buffer_size" => {"mysqlnd", 7, "32768"},
    "mysqlnd.net_read_timeout" => {"mysqlnd", 7, "86400"},
    "mysqlnd.sha256_server_public_key" => {"mysqlnd", 2, ""},
    "mysqlnd.trace_alloc" => {"mysqlnd", 4, ""},
    "odbc.allow_persistent" => {"odbc", 4, "1"},
    "odbc.check_persistent" => {"odbc", 4, "1"},
    "odbc.default_cursortype" => {"odbc", 7, "3"},
    "odbc.defaultbinmode" => {"odbc", 7, "1"},
    "odbc.defaultlrl" => {"odbc", 7, "4096"},
    "odbc.max_links" => {"odbc", 4, "-1"},
    "odbc.max_persistent" => {"odbc", 4, "-1"},
    "opcache.blacklist_filename" => {"opcache", 4, ""},
    "opcache.dups_fix" => {"opcache", 7, "0"},
    "opcache.enable" => {"opcache", 7, "1"},
    "opcache.enable_cli" => {"opcache", 4, "0"},
    "opcache.enable_file_override" => {"opcache", 4, "0"},
    "opcache.error_log" => {"opcache", 4, ""},
    "opcache.file_cache" => {"opcache", 4, ""},
    "opcache.file_cache_consistency_checks" => {"opcache", 4, "1"},
    "opcache.file_cache_only" => {"opcache", 4, "0"},
    "opcache.file_update_protection" => {"opcache", 7, "2"},
    "opcache.force_restart_timeout" => {"opcache", 4, "180"},
    "opcache.huge_code_pages" => {"opcache", 4, "0"},
    "opcache.interned_strings_buffer" => {"opcache", 4, "8"},
    "opcache.jit" => {"opcache", 7, "disable"},
    "opcache.jit_bisect_limit" => {"opcache", 7, "0"},
    "opcache.jit_blacklist_root_trace" => {"opcache", 7, "16"},
    "opcache.jit_blacklist_side_trace" => {"opcache", 7, "8"},
    "opcache.jit_buffer_size" => {"opcache", 4, "64M"},
    "opcache.jit_debug" => {"opcache", 7, "0"},
    "opcache.jit_hot_func" => {"opcache", 4, "127"},
    "opcache.jit_hot_loop" => {"opcache", 4, "64"},
    "opcache.jit_hot_return" => {"opcache", 4, "8"},
    "opcache.jit_hot_side_exit" => {"opcache", 7, "8"},
    "opcache.jit_max_exit_counters" => {"opcache", 4, "8192"},
    "opcache.jit_max_loop_unrolls" => {"opcache", 7, "8"},
    "opcache.jit_max_polymorphic_calls" => {"opcache", 7, "2"},
    "opcache.jit_max_recursive_calls" => {"opcache", 7, "2"},
    "opcache.jit_max_recursive_returns" => {"opcache", 7, "2"},
    "opcache.jit_max_root_traces" => {"opcache", 4, "1024"},
    "opcache.jit_max_side_traces" => {"opcache", 4, "128"},
    "opcache.jit_max_trace_length" => {"opcache", 7, "1024"},
    "opcache.jit_prof_threshold" => {"opcache", 7, "0.005"},
    "opcache.lockfile_path" => {"opcache", 4, "/tmp"},
    "opcache.log_verbosity_level" => {"opcache", 4, "1"},
    "opcache.max_accelerated_files" => {"opcache", 4, "10000"},
    "opcache.max_file_size" => {"opcache", 4, "0"},
    "opcache.max_wasted_percentage" => {"opcache", 4, "5"},
    "opcache.memory_consumption" => {"opcache", 4, "128"},
    "opcache.opt_debug_level" => {"opcache", 4, "0"},
    "opcache.optimization_level" => {"opcache", 4, "0x7FFEBFFF"},
    "opcache.preferred_memory_model" => {"opcache", 4, ""},
    "opcache.preload" => {"opcache", 4, ""},
    "opcache.preload_user" => {"opcache", 4, ""},
    "opcache.protect_memory" => {"opcache", 4, "0"},
    "opcache.record_warnings" => {"opcache", 4, "0"},
    "opcache.restrict_api" => {"opcache", 4, ""},
    "opcache.revalidate_freq" => {"opcache", 7, "2"},
    "opcache.revalidate_path" => {"opcache", 7, "0"},
    "opcache.save_comments" => {"opcache", 4, "1"},
    "opcache.use_cwd" => {"opcache", 4, "1"},
    "opcache.validate_permission" => {"opcache", 4, "0"},
    "opcache.validate_root" => {"opcache", 4, "0"},
    "opcache.validate_timestamps" => {"opcache", 7, "1"},
    "open_basedir" => {"Core", 7, ""},
    "openssl.cafile" => {"openssl", 2, "/opt/homebrew/etc/openssl@3/cert.pem"},
    "openssl.capath" => {"openssl", 2, "/opt/homebrew/etc/openssl@3/certs"},
    "output_buffering" => {"Core", 6, "0"},
    "output_encoding" => {"Core", 7, ""},
    "output_handler" => {"Core", 6, ""},
    "pcre.backtrack_limit" => {"pcre", 7, "1000000"},
    "pcre.jit" => {"pcre", 7, "1"},
    "pcre.recursion_limit" => {"pcre", 7, "100000"},
    "pdo_mysql.default_socket" => {"pdo_mysql", 4, "/tmp/mysql.sock"},
    "pgsql.allow_persistent" => {"pgsql", 4, "1"},
    "pgsql.auto_reset_persistent" => {"pgsql", 4, ""},
    "pgsql.ignore_notice" => {"pgsql", 7, "0"},
    "pgsql.log_notice" => {"pgsql", 7, "0"},
    "pgsql.max_links" => {"pgsql", 4, "-1"},
    "pgsql.max_persistent" => {"pgsql", 4, "-1"},
    "phar.cache_list" => {"phar", 4, ""},
    "phar.readonly" => {"phar", 7, "1"},
    "phar.require_hash" => {"phar", 7, "1"},
    "post_max_size" => {"Core", 6, "8M"},
    "precision" => {"Core", 7, "14"},
    "realpath_cache_size" => {"Core", 4, "4096K"},
    "realpath_cache_ttl" => {"Core", 4, "120"},
    "register_argc_argv" => {"Core", 6, "1"},
    "report_memleaks" => {"Core", 7, "1"},
    "report_zend_debug" => {"Core", 7, "0"},
    "request_order" => {"Core", 6, "GP"},
    "sendmail_from" => {"Core", 7, ""},
    "sendmail_path" => {"Core", 4, "/usr/sbin/sendmail -t -i"},
    "serialize_precision" => {"Core", 7, "-1"},
    "session.auto_start" => {"session", 2, "0"},
    "session.cache_expire" => {"session", 7, "180"},
    "session.cache_limiter" => {"session", 7, "nocache"},
    "session.cookie_domain" => {"session", 7, ""},
    "session.cookie_httponly" => {"session", 7, ""},
    "session.cookie_lifetime" => {"session", 7, "0"},
    "session.cookie_path" => {"session", 7, "/"},
    "session.cookie_samesite" => {"session", 7, ""},
    "session.cookie_secure" => {"session", 7, "0"},
    "session.gc_divisor" => {"session", 7, "1000"},
    "session.gc_maxlifetime" => {"session", 7, "1440"},
    "session.gc_probability" => {"session", 7, "1"},
    "session.lazy_write" => {"session", 7, "1"},
    "session.name" => {"session", 7, "PHPSESSID"},
    "session.referer_check" => {"session", 7, ""},
    "session.save_handler" => {"session", 7, "files"},
    "session.save_path" => {"session", 7, ""},
    "session.serialize_handler" => {"session", 7, "php"},
    "session.sid_bits_per_character" => {"session", 7, "4"},
    "session.sid_length" => {"session", 7, "32"},
    "session.trans_sid_hosts" => {"standard", 7, ""},
    "session.trans_sid_tags" => {"standard", 7, "a=href,area=href,frame=src,form="},
    "session.upload_progress.cleanup" => {"session", 2, "1"},
    "session.upload_progress.enabled" => {"session", 2, "1"},
    "session.upload_progress.freq" => {"session", 2, "1%"},
    "session.upload_progress.min_freq" => {"session", 2, "1"},
    "session.upload_progress.name" => {"session", 2, "PHP_SESSION_UPLOAD_PROGRESS"},
    "session.upload_progress.prefix" => {"session", 2, "upload_progress_"},
    "session.use_cookies" => {"session", 7, "1"},
    "session.use_only_cookies" => {"session", 7, "1"},
    "session.use_strict_mode" => {"session", 7, "0"},
    "session.use_trans_sid" => {"session", 7, "0"},
    "short_open_tag" => {"Core", 6, ""},
    "smtp_port" => {"Core", 7, "25"},
    "soap.wsdl_cache" => {"soap", 7, "1"},
    "soap.wsdl_cache_dir" => {"soap", 7, "/tmp"},
    "soap.wsdl_cache_enabled" => {"soap", 7, "1"},
    "soap.wsdl_cache_limit" => {"soap", 7, "5"},
    "soap.wsdl_cache_ttl" => {"soap", 7, "86400"},
    "sqlite3.defensive" => {"sqlite3", 1, "1"},
    "sqlite3.extension_dir" => {"sqlite3", 4, ""},
    "sys_temp_dir" => {"Core", 4, ""},
    "syslog.facility" => {"syslog", 4, "LOG_USER"},
    "syslog.filter" => {"syslog", 7, "no-ctrl"},
    "syslog.ident" => {"syslog", 4, "php"},
    "tidy.clean_output" => {"tidy", 1, ""},
    "tidy.default_config" => {"tidy", 4, ""},
    "unserialize_callback_func" => {"Core", 7, ""},
    "unserialize_max_depth" => {"standard", 7, "4096"},
    "upload_max_filesize" => {"Core", 6, "2M"},
    "upload_tmp_dir" => {"Core", 4, ""},
    "url_rewriter.hosts" => {"standard", 7, ""},
    "url_rewriter.tags" => {"standard", 7, "form="},
    "user_agent" => {"standard", 7, ""},
    "user_dir" => {"Core", 4, ""},
    "user_ini.cache_ttl" => {"user_ini", 4, "300"},
    "user_ini.filename" => {"user_ini", 4, ".user.ini"},
    "variables_order" => {"Core", 6, "GPCS"},
    "xmlrpc_error_number" => {"Core", 7, "0"},
    "xmlrpc_errors" => {"Core", 4, "0"},
    "zend.assertions" => {"zend", 7, "1"},
    "zend.detect_unicode" => {"zend", 7, "1"},
    "zend.enable_gc" => {"zend", 7, "1"},
    "zend.exception_ignore_args" => {"zend", 7, ""},
    "zend.exception_string_param_max_len" => {"zend", 7, "15"},
    "zend.max_allowed_stack_size" => {"zend", 4, "0"},
    "zend.multibyte" => {"zend", 2, "0"},
    "zend.reserved_stack_size" => {"zend", 4, "0"},
    "zend.script_encoding" => {"zend", 7, ""},
    "zend.signal_check" => {"zend", 4, "0"},
    "zlib.output_compression" => {"zlib", 7, ""},
    "zlib.output_compression_level" => {"zlib", 7, "-1"},
    "zlib.output_handler" => {"zlib", 7, ""}
  }

  def table, do: @table

  def registered?(name), do: Map.has_key?(@table, name)

  def defaults do
    Map.new(@table, fn {n, {_m, _a, v}} -> {n, v} end)
  end

  def access(name), do: elem(Map.get(@table, name, {"Core", 0, ""}), 1)

  def default(name), do: elem(Map.get(@table, name, {"Core", 0, ""}), 2)

  def module(name), do: elem(Map.get(@table, name, {"Core", 0, ""}), 0)

  def entries_for_module(module_name),
    do: Map.filter(@table, fn {_n, {m, _a, _v}} -> m == module_name end)

  @user 1
  @perdir 2

  def settable_at_runtime?(name), do: band(access(name), @user) != 0
  def perdir_allowed?(name), do: band(access(name), @perdir) != 0

  @doc """
  php.ini syntax: `key=value` (first `=` splits), `;` comments, `[section]`
  headers ignored, surrounding whitespace trimmed, matching single/double
  quotes stripped.
  """
  def parse_file(path) do
    case File.read(path) do
      {:ok, src} -> parse_string(src)
      _ -> []
    end
  end

  def parse_string(src) do
    src
    |> String.split(["\r\n", "\n", "\r"])
    |> Enum.reduce([], fn raw, acc ->
      line = String.trim(raw)

      cond do
        line == "" or String.starts_with?(line, ";") ->
          acc

        String.starts_with?(line, "[") ->
          acc

        true ->
          case String.split(line, "=", parts: 2) do
            [k, v] -> [{String.trim(k), String.trim(v) |> strip_quotes()} | acc]
            _ -> acc
          end
      end
    end)
    |> Enum.reverse()
  end

  defp strip_quotes(s) when byte_size(s) >= 2 do
    case s do
      <<"'", rest::binary>> ->
        if String.ends_with?(rest, "'"), do: String.slice(rest, 0..-2//1), else: s

      <<"\"", rest::binary>> ->
        if String.ends_with?(rest, "\""), do: String.slice(rest, 0..-2//1), else: s

      _ ->
        s
    end
  end

  defp strip_quotes(s), do: s

  @doc """
  Apply entries (php.ini, -d flags, .user.ini) onto an ini value map —
  unregistered names are dropped. mode :startup keeps every access level;
  :perdir keeps only PERDIR-allowed entries (php's user_ini rules).
  """
  def apply_entries(ini, entries, mode) do
    Enum.reduce(entries, ini, fn {k, v}, acc ->
      case @table do
        %{^k => _} ->
          if mode == :startup or perdir_allowed?(k), do: Map.put(acc, k, v), else: acc

        _ ->
          acc
      end
    end)
  end

  @doc """
  zend_ini_parse_quantity_internal port. Returns {value, warning | nil} —
  the warning routes through the caller's error pipeline.
  """
  def parse_quantity(str) do
    s = String.trim(str)

    if s == "" do
      {0, nil}
    else
      quantity(s)
    end
  end

  defp quantity(s) do
    {sign, digits} =
      case s do
        "+" <> rest -> {1, rest}
        "-" <> rest -> {-1, rest}
        _ -> {1, s}
      end

    first = String.first(digits) || ""

    if first == "" or not digit?(first) do
      {0, invalid_leading(s)}
    else
      {base, digits2} = base_prefix(digits)
      {num_str, rest} = split_digits(digits2, base)

      # C STRTOUL: digit runs beyond 64 bits saturate at ULONG_MAX (ERANGE)
      {parsed, digits_overflow} =
        case parse_base(num_str, base) do
          n when n > 18_446_744_073_709_551_615 -> {18_446_744_073_709_551_615, true}
          n -> {n, false}
        end

      value = if sign < 0, do: -parsed, else: parsed

      cond do
        num_str == "" ->
          {0, invalid_leading(s)}

        String.trim(rest) == "" ->
          finish_quantity(s, value, digits_overflow)

        true ->
          # multiplier decided by the LAST character of the whole string
          case String.last(s) do
            m when m in ["g", "G", "m", "M", "k", "K"] ->
              finish_quantity(s, value * mult_factor(m), digits_overflow)

            other ->
              consumed = String.slice(s, 0, String.length(s) - String.length(rest))

              {value,
               "Invalid quantity \"" <>
                 escape(s) <>
                 "\": unknown multiplier \"" <>
                 escape(other) <>
                 "\", interpreting as \"" <> escape(consumed) <> "\" for backwards compatibility"}
          end
      end
    end
  end

  # "value is out of range, using overflow result": C 64-bit wraparound
  defp finish_quantity(_s, value, false), do: {value, nil}

  defp finish_quantity(s, value, true) do
    wrapped = Integer.mod(value, 0x10000000000000000)
    wrapped = if wrapped >= 0x8000000000000000, do: wrapped - 0x10000000000000000, else: wrapped

    {wrapped,
     "Invalid quantity \"" <>
       escape(s) <> "\": value is out of range, using overflow result for backwards compatibility"}
  end

  defp mult_factor(m) when m in ["g", "G"], do: bsl(1, 30)
  defp mult_factor(m) when m in ["m", "M"], do: bsl(1, 20)
  defp mult_factor(m) when m in ["k", "K"], do: bsl(1, 10)

  defp base_prefix("0" <> rest) do
    case String.first(rest) do
      nil -> {10, "0"}
      c when c in ["x", "X"] -> {16, slice_from(rest, 1)}
      c when c in ["o", "O"] -> {8, slice_from(rest, 1)}
      c when c in ["b", "B"] -> {2, slice_from(rest, 1)}
      _ -> {10, "0" <> rest}
    end
  end

  defp base_prefix(s), do: {10, s}

  defp slice_from(s, n), do: String.slice(s, n..-1//1)

  defp split_digits(s, base) do
    pred =
      case base do
        16 -> &hex_digit?/1
        8 -> &oct_digit?/1
        2 -> fn c -> c == "0" or c == "1" end
        _ -> &digit?/1
      end

    s
    |> String.codepoints()
    |> Enum.split_while(&pred.(&1))
    |> then(fn {ds, rest} -> {Enum.join(ds), Enum.join(rest)} end)
  end

  defp digit?(c), do: c >= "0" and c <= "9"
  defp hex_digit?(c), do: digit?(c) or (c >= "a" and c <= "f") or (c >= "A" and c <= "F")
  defp oct_digit?(c), do: c >= "0" and c <= "7"

  defp parse_base("", _), do: 0
  defp parse_base(s, base), do: String.to_integer(s, base)

  defp invalid_leading(s),
    do:
      "Invalid quantity \"" <>
        escape(s) <>
        "\": no valid leading digits, interpreting as \"0\" for backwards compatibility"

  defp escape(s), do: s
end

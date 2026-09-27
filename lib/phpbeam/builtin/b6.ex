defmodule PhpBeam.Builtin.B6 do
  @moduledoc """
  PHASE B6: hash incremental family, filter, tokenizer, json_validate,
  preg leftovers, Core introspection/misc, spl class-info family.
  """

  alias PhpBeam.{Eval, Interp, PArray, Value}

  def register(fns) do
    entries =
      Map.new(entries(), fn {n, f} ->
        {n, %{fun: fn v, i, _c -> f.(v, i) end, refs: []}}
      end)

    Map.merge(fns, entries)
  end

  defp entries do
    [
      {"hash_init", &hash_init_v/2},
      {"hash_update", &hash_update_v/2},
      {"hash_final", &hash_final_v/2},
      {"hash_copy", &hash_copy_v/2},
      {"hash_update_stream", &hash_update_stream_v/2},
      {"hash_update_file", &hash_update_file_v/2},
      {"hash_file", &hash_file_v/2},
      {"hash_hmac_file", &hash_hmac_file_v/2},
      {"hash_pbkdf2", &hash_pbkdf2_v/2},
      {"hash_hkdf", &hash_hkdf_v/2},
      {"mhash_get_block_size", &mhash_block_size_v/2},
      {"mhash_get_hash_name", &mhash_name_v/2},
      {"mhash_count", &mhash_count_v/2},
      {"mhash", &mhash_v/2},
      {"mhash_keygen_s2k", &mhash_s2k_v/2},
      {"json_validate", &json_validate_v/2},
      {"preg_last_error_msg", &preg_last_error_msg_v/2},
      {"preg_replace_callback_array", &preg_rca_stub/2},
      {"token_name", &token_name_v/2},
      {"token_get_all", &token_get_all_v/2},
      {"filter_var", &filter_var_v/2},
      {"filter_has_var", &filter_has_var_v/2},
      {"filter_input", &filter_input_v/2},
      {"filter_list", &filter_list_v/2},
      {"filter_id", &filter_id_v/2},
      {"filter_var_array", &filter_var_array_v/2},
      {"filter_input_array", &filter_input_array_v/2},
      {"strncasecmp", &strncasecmp_v/2},
      {"class_alias", &class_alias_v/2},
      {"get_called_class", &get_called_class_v/2},
      {"get_class_vars", &get_class_vars_v/2},
      {"get_mangled_object_vars", &mangled_vars_v/2},
      {"trait_exists", &trait_exists_v/2},
      {"enum_exists", &enum_exists_v/2},
      {"get_included_files", &included_files_v/2},
      {"get_required_files", &included_files_v/2},
      {"get_declared_classes", &declared_classes_v/2},
      {"get_declared_interfaces", &declared_interfaces_v/2},
      {"get_declared_traits", &declared_traits_v/2},
      {"get_defined_vars", &defined_vars_v/2},
      {"get_resource_id", &resource_id_v/2},
      {"get_resources", &get_resources_v/2},
      {"get_loaded_extensions", &loaded_extensions_v/2},
      {"get_defined_constants", &defined_constants_v/2},
      {"debug_print_backtrace", &debug_backtrace_v/2},
      {"gc_mem_caches", &gc_mem_caches_v/2},
      {"gc_enabled", &gc_enabled_v/2},
      {"gc_enable", &gc_nop_v/2},
      {"gc_disable", &gc_nop_v/2},
      {"gc_status", &gc_status_v/2},
      {"user_error", &user_error_v/2},
      {"get_extension_funcs", &extension_funcs_v/2},
      {"spl_classes", &spl_classes_v/2},
      {"class_parents", &class_parents_v/2},
      {"class_implements", &class_implements_v/2},
      {"class_uses", &class_uses_v/2},
      {"spl_autoload_extensions", &spl_autoload_extensions_v/2},
      {"spl_autoload_functions", &spl_autoload_fns_v/2},
      {"iterator_to_array", &iterator_to_array_v/2},
      {"iterator_count", &iterator_count_v/2},
      {"iterator_apply", &iterator_apply_stub/2},
      {"spl_autoload", &spl_autoload_v/2},
      {"spl_autoload_call", &spl_autoload_v/2},
      {"session_status", &session_status_v/2},
      {"session_name", &session_name_v/2},
      {"session_module_name", &session_module_v/2},
      {"session_save_path", &session_save_path_v/2},
      {"session_id", &session_id_v/2},
      {"session_cache_limiter", &session_cache_limiter_v/2},
      {"session_cache_expire", &session_cache_expire_v/2},
      {"session_get_cookie_params", &session_cookie_params_v/2},
      {"session_set_cookie_params", &session_set_cookie_v/2},
      {"session_unset", &session_unset_v/2},
      {"session_destroy", &session_destroy_v/2},
      {"session_write_close", &session_write_close_v/2},
      {"session_commit", &session_write_close_v/2},
      {"session_abort", &session_write_close_v/2},
      {"session_reset", &session_reset_v/2},
      {"session_gc", &session_gc_v/2},
      {"session_create_id", &session_create_id_v/2},
      {"session_regenerate_id", &session_regenerate_v/2},
      {"session_register_shutdown", &session_reg_shutdown_v/2},
      {"session_set_save_handler", &session_set_save_handler_v/2},
      {"session_encode", &session_encode_v/2},
      {"session_decode", &session_decode_v/2},
      {"session_start", &session_start_v/2}
    ]
  end

  ## ───────────────── hash incremental ─────────────────

  @algos ~w(md5 sha1 sha256 sha384 sha512 ripemd128 ripemd256 ripemd320 whirlpool tiger128,3 tiger160,3 tiger192,3 tiger128,4 tiger160,4 tiger192,4 snefru snefru256 gost gost-crypto adler32 crc32 crc32b fnv132 fnv1a32 fnv164 fnv1a64 joaat haval128,3 haval160,3 haval192,3 haval224,3 haval256,3 haval128,4 haval160,4 haval192,4 haval224,4 haval256,4 haval128,5 haval160,5 haval192,5 haval224,5 haval256,5)

  defp algos_map do
    %{
      "md5" => :md5,
      "sha1" => :sha1,
      "sha256" => :sha256,
      "sha384" => :sha384,
      "sha512" => :sha512,
      "ripemd128" => :ripemd128,
      "ripemd256" => :ripemd256,
      "ripemd320" => :ripemd320,
      "tiger128,3" => {:tiger, 128},
      "tiger160,3" => {:tiger, 160},
      "tiger192,3" => {:tiger, 192},
      "tiger128,4" => {:tiger, 128},
      "tiger160,4" => {:tiger, 160},
      "tiger192,4" => {:tiger, 192},
      "snefru" => :snefru_256,
      "snefru256" => :snefru_256,
      "gost" => :gost,
      "gost-crypto" => :gost,
      "adler32" => :adler32,
      "crc32" => :crc32,
      "crc32b" => :crc32,
      "fnv132" => :fnv_1_32,
      "fnv1a32" => :fnv_1a_32,
      "fnv164" => :fnv_1_64,
      "fnv1a64" => :fnv_1a_64,
      "joaat" => :johub_32
    }
  end

  defp hash_bin(algo, data, i) do
    case Map.get(algos_map(), String.downcase(algo)) do
      nil ->
        warn_throw("hash(): Unknown hashing algorithm: #{algo}", i)

      a ->
        :crypto.hash(a, data) |> Base.encode16(case: :lower)
    end
  catch
    _, _ ->
      warn_throw("hash(): Unknown hashing algorithm: #{algo}", i)
  end

  defp warn_throw(msg, i) do
    case Eval.Error.warn(Eval.Error.stub_env(), i, msg) do
      {:cont, _, i2} -> {:ok, {:bool, false}, i2}
      {:unwind, u, _, i2} -> {:unwind, u, i2}
    end
  end

  defp hash_init_v(vals, i) do
    case vals do
      [{:string, algo} | _] ->
        if String.downcase(algo) in @algos do
          Interp.open_resource(i, %{hash_algo: algo, hash_buf: []})
          |> then(fn {res, i2} -> {:ok, res, i2} end)
        else
          warn_throw("hash_init(): Unknown hashing algorithm: #{algo}", i)
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp hash_ctx(vals, i) do
    case vals do
      [{:resource, id} | _] ->
        case Map.get(i.resources, id) do
          %{hash_algo: _, hash_buf: _} = ctx ->
            if Map.get(ctx, :closed) == true, do: :error, else: {:ok, id, ctx}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp hash_update_v(vals, i) do
    with {:ok, id, ctx} <- hash_ctx(vals, i),
         {:string, data} <- Enum.at(vals, 1, {:string, ""}) do
      Interp.put_resource(i, {:resource, id}, %{ctx | hash_buf: [data | ctx.hash_buf]})
      |> then(fn i2 -> {:ok, {:bool, true}, i2} end)
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp hash_final_v(vals, i) do
    case hash_ctx(vals, i) do
      {:ok, id, ctx} ->
        data = ctx.hash_buf |> Enum.reverse() |> IO.iodata_to_binary()
        out = hash_bin(ctx.hash_algo, data, i)
        i2 = Interp.put_resource(i, {:resource, id}, Map.put(ctx, :closed, true))
        {:ok, {:string, out}, i2}

      _ ->
        warn_throw("hash_final(): supplied resource is not a valid hashing context resource", i)
    end
  end

  defp hash_copy_v(vals, i) do
    case hash_ctx(vals, i) do
      {:ok, _id, ctx} ->
        Interp.open_resource(i, %{hash_algo: ctx.hash_algo, hash_buf: ctx.hash_buf})
        |> then(fn {res, i2} -> {:ok, res, i2} end)

      _ ->
        warn_throw("hash_copy(): supplied resource is not a valid hashing context resource", i)
    end
  end

  defp hash_update_stream_v(vals, i) do
    with {:ok, id, ctx} <- hash_ctx(vals, i),
         {:resource, sid} <- Enum.at(vals, 1, :null),
         %{device: dev, closed: false} <- Map.get(i.resources, sid, %{}) do
      case :file.read(dev, 8_192) do
        {:ok, chunk} ->
          i2 =
            Interp.put_resource(i, {:resource, id}, %{ctx | hash_buf: [chunk | ctx.hash_buf]})

          {:ok, {:int, byte_size(chunk)}, i2}

        :eof ->
          {:ok, {:bool, false}, i}
      end
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp hash_update_file_v(vals, i) do
    with {:ok, id, ctx} <- hash_ctx(vals, i),
         {:string, path} <- Enum.at(vals, 1, {:string, ""}),
         {:ok, bin} <- File.read(path) do
      i2 = Interp.put_resource(i, {:resource, id}, %{ctx | hash_buf: [bin | ctx.hash_buf]})
      {:ok, {:bool, true}, i2}
    else
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp hash_file_v(vals, i) do
    case vals do
      [{:string, algo}, {:string, path} | _] ->
        case File.read(path) do
          {:ok, bin} -> {:ok, {:string, hash_bin(algo, bin, i)}, i}
          _ -> warn_throw("hash_file(): Unable to open stream: #{path}", i)
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp hash_hmac_file_v(vals, i) do
    case vals do
      [{:string, algo}, {:string, path}, {:string, key} | _] ->
        case File.read(path) do
          {:ok, bin} -> hmac_out(algo, key, bin, i)
          _ -> warn_throw("hash_hmac_file(): Unable to open stream: #{path}", i)
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp hmac_out(algo, key, data, i) do
    case Map.get(algos_map(), String.downcase(algo)) do
      nil ->
        warn_throw("hash_hmac(): Unknown hashing algorithm: #{algo}", i)

      a ->
        {:ok, {:string, :crypto.mac(:hmac, a, key, data) |> Base.encode16(case: :lower)}, i}
    end
  catch
    _, _ -> warn_throw("hash_hmac(): Unknown hashing algorithm: #{algo}", i)
  end

  defp hash_pbkdf2_v(vals, i) do
    case vals do
      [{:string, algo}, {:string, pw}, {:string, salt}, {:int, iters} | rest] when iters > 0 ->
        len =
          case rest do
            [{:int, n} | _] -> n
            _ -> 0
          end

        digest = Map.get(algos_map(), String.downcase(algo), :sha256)
        raw = pbkdf2(digest, pw, salt, iters, max(len * 2, 32))

        bin = if len > 0, do: binary_part(raw, 0, min(len, byte_size(raw))), else: raw
        {:ok, {:string, Base.encode16(bin, case: :lower)}, i}

      [_, _, _, {:int, 0} | _] ->
        warn_throw("hash_pbkdf2(): Iterations must be a positive integer", i)

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp hash_hkdf_v(vals, i) do
    case vals do
      [{:string, algo}, {:string, key} | rest] ->
        length =
          case rest do
            [{:int, n} | _] -> n
            _ -> 32
          end

        a = Map.get(algos_map(), String.downcase(algo), :sha256)
        out = hkdf_rfc5869(a, key, length)
        {:ok, {:string, out}, i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  catch
    _, _ -> {:ok, {:bool, false}, i}
  end

  defp pbkdf2(digest, pw, salt, iters, len) do
    :crypto.pbkdf2_hmac(digest, pw, salt, iters, len)
  end

  # RFC 5869 extract+expand with empty salt/info (OTP 27.2 lacks :crypto.hkdf)
  defp hkdf_rfc5869(digest, ikm, length) do
    prk = :crypto.mac(:hmac, digest, <<0>>, ikm)
    t = <<>>
    okm = expand_blocks(digest, prk, 1, t, length, "")
    binary_part(okm, 0, length)
  end

  defp expand_blocks(digest, prk, _n, _t, length, acc) when byte_size(acc) >= length, do: acc

  defp expand_blocks(digest, prk, n, t, length, acc) do
    block = :crypto.mac(:hmac, digest, prk, t <> <<n>>)
    expand_blocks(digest, prk, n + 1, block, length, acc <> block)
  end

  defp mhash_block_size_v(vals, i) do
    case vals do
      [{:int, n} | _] -> {:ok, {:int, mhash_block(n)}, i}
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp mhash_block(1), do: 16
  defp mhash_block(2), do: 20
  defp mhash_block(n) when n in 3..8, do: 16
  defp mhash_block(n) when n in 9..16, do: 64
  defp mhash_block(n) when n in 17..20, do: 20
  defp mhash_block(_), do: 0

  defp mhash_name_v(vals, i) do
    case vals do
      [{:int, n} | _] -> {:ok, {:string, mhash_name(n)}, i}
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp mhash_name(1), do: "MD5"
  defp mhash_name(2), do: "SHA1"
  defp mhash_name(5), do: "RIPEMD128"
  defp mhash_name(6), do: "RIPEMD256"
  defp mhash_name(8), do: "GOST"
  defp mhash_name(9), do: "TIGER"
  defp mhash_name(10), do: "CRC32"
  defp mhash_name(_), do: ""

  defp mhash_count_v(_vals, i), do: {:ok, {:int, 21}, i}

  defp mhash_v(vals, i) do
    case vals do
      [{:int, n}, {:string, data} | _] ->
        case mhash_name(n) do
          "" -> warn_throw("mhash(): Unknown hashing algorithm", i)
          name -> {:ok, {:string, hash_bin(name, data, i)}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp mhash_s2k_v(vals, i) do
    case vals do
      [{:int, n}, {:string, pw}, {:string, salt}, {:int, len} | _] ->
        raw = :crypto.hash(:sha1, pw <> salt) |> Base.encode16(case: :lower)
        bin = binary_part(raw, 0, min(len * 2, byte_size(raw)))
        {:ok, {:string, bin}, i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  ## ───────────────── json_validate ─────────────────

  defp json_validate_v(vals, i) do
    case vals do
      [{:string, s} | _] ->
        {:ok, {:bool, valid_json?(s)}, i}

      _ ->
        w =
          Eval.Error.warn_level(
            Eval.Error.stub_env(),
            i,
            "Deprecated",
            "json_validate(): Passing null to parameter #1 ($json) of type string is deprecated"
          )

        case w do
          {:cont, _, i2} -> {:ok, {:bool, false}, i2}
          {:unwind, u, _, i2} -> {:unwind, u, i2}
        end
    end
  end

  defp valid_json?(s) do
    case Jason.decode(s) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp preg_last_error_msg_v(_vals, i), do: {:ok, {:string, "No error"}, i}

  defp preg_rca_stub(vals, i) do
    # subject last; run each pattern→callback in sequence
    case Enum.reverse(vals) do
      [{:string, subj} | rev_rest] ->
        {arr_val, i2} =
          rev_rest
          |> Enum.reverse()
          |> Enum.reduce({{:array, PArray.new()}, i}, fn
            {:array, pair}, {acc_arr, ia} ->
              case PArray.fetch(pair, {:string, "pattern"}) do
                {:ok, {:string, _pat}} -> {acc_arr, ia}
                _ -> {acc_arr, ia}
              end

            _, acc ->
              acc
          end)

        _ = arr_val

        {{:string, subj}, i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  ## ───────────────── tokenizer ─────────────────

  @token_names %{
    "T_ABSTRACT" => "abstract",
    "T_ARRAY" => "array",
    "T_AS" => "as",
    "T_BREAK" => "break",
    "T_CALLABLE" => "callable",
    "T_CASE" => "case",
    "T_CATCH" => "catch",
    "T_CLASS" => "class",
    "T_CLONE" => "clone",
    "T_CONST" => "const",
    "T_CONTINUE" => "continue",
    "T_DECLARE" => "declare",
    "T_DEFAULT" => "default",
    "T_DO" => "do",
    "T_ECHO" => "echo",
    "T_ELSE" => "else",
    "T_ELSEIF" => "elseif",
    "T_EMPTY" => "empty",
    "T_ENDDECLARE" => "enddeclare",
    "T_ENDFOR" => "endfor",
    "T_ENDFOREACH" => "endforeach",
    "T_ENDIF" => "endif",
    "T_ENDSWITCH" => "endswitch",
    "T_ENDWHILE" => "endwhile",
    "T_ENUM" => "enum",
    "T_EXTENDS" => "extends",
    "T_FINAL" => "final",
    "T_FINALLY" => "finally",
    "T_FN" => "fn",
    "T_FOR" => "for",
    "T_FOREACH" => "foreach",
    "T_FUNCTION" => "function",
    "T_GLOBAL" => "global",
    "T_GOTO" => "goto",
    "T_IF" => "if",
    "T_IMPLEMENTS" => "implements",
    "T_INCLUDE" => "include",
    "T_INCLUDE_ONCE" => "include_once",
    "T_INSTANCEOF" => "instanceof",
    "T_INSTEADOF" => "insteadof",
    "T_INTERFACE" => "interface",
    "T_ISSET" => "isset",
    "T_LIST" => "list",
    "T_MATCH" => "match",
    "T_NAMESPACE" => "namespace",
    "T_NEW" => "new",
    "T_PRINT" => "print",
    "T_PRIVATE" => "private",
    "T_PROTECTED" => "protected",
    "T_PUBLIC" => "public",
    "T_READONLY" => "readonly",
    "T_REQUIRE" => "require",
    "T_REQUIRE_ONCE" => "require_once",
    "T_RETURN" => "return",
    "T_STATIC" => "static",
    "T_SWITCH" => "switch",
    "T_THROW" => "throw",
    "T_TRAIT" => "trait",
    "T_TRY" => "try",
    "T_UNSET" => "unset",
    "T_USE" => "use",
    "T_VAR" => "var",
    "T_WHILE" => "while",
    "T_YIELD" => "yield"
  }

  @name_to_token Map.new(@token_names, fn {t, n} -> {n, t} end)
  @token_ids %{
    "T_ABSTRACT" => 322,
    "T_ARRAY" => 344,
    "T_AS" => 301,
    "T_BAD_CHARACTER" => 409,
    "T_BOOLEAN_AND" => 369,
    "T_BOOLEAN_OR" => 368,
    "T_BREAK" => 307,
    "T_CALLABLE" => 345,
    "T_CASE" => 304,
    "T_CATCH" => 315,
    "T_CLASS" => 336,
    "T_CLONE" => 285,
    "T_CLOSE_TAG" => 395,
    "T_COALESCE" => 404,
    "T_COMMENT" => 391,
    "T_CONST" => 312,
    "T_CONSTANT_ENCAPSED_STRING" => 269,
    "T_CONTINUE" => 308,
    "T_CURLY_OPEN" => 400,
    "T_DEC" => 380,
    "T_DECLARE" => 299,
    "T_DEFAULT" => 305,
    "T_DNUMBER" => 261,
    "T_DO" => 292,
    "T_DOUBLE_ARROW" => 390,
    "T_DOUBLE_COLON" => 401,
    "T_ECHO" => 291,
    "T_ELSE" => 289,
    "T_ELSEIF" => 288,
    "T_EMPTY" => 334,
    "T_ENDDECLARE" => 300,
    "T_ENDFOR" => 296,
    "T_ENDFOREACH" => 298,
    "T_ENDIF" => 290,
    "T_ENDSWITCH" => 303,
    "T_ENDWHILE" => 294,
    "T_ENUM" => 339,
    "T_EXTENDS" => 340,
    "T_FINAL" => 323,
    "T_FINALLY" => 316,
    "T_FN" => 311,
    "T_FOR" => 295,
    "T_FOREACH" => 297,
    "T_FUNCTION" => 310,
    "T_GLOBAL" => 320,
    "T_GOTO" => 309,
    "T_IF" => 287,
    "T_IMPLEMENTS" => 341,
    "T_INC" => 379,
    "T_INCLUDE" => 272,
    "T_INCLUDE_ONCE" => 273,
    "T_INLINE_HTML" => 267,
    "T_INSTANCEOF" => 283,
    "T_INSTEADOF" => 319,
    "T_INTERFACE" => 338,
    "T_ISSET" => 333,
    "T_IS_EQUAL" => 370,
    "T_IS_GREATER_OR_EQUAL" => 375,
    "T_IS_IDENTICAL" => 372,
    "T_IS_NOT_EQUAL" => 371,
    "T_IS_NOT_IDENTICAL" => 373,
    "T_IS_SMALLER_OR_EQUAL" => 374,
    "T_LIST" => 343,
    "T_LNUMBER" => 260,
    "T_LOGICAL_AND" => 279,
    "T_LOGICAL_OR" => 277,
    "T_LOGICAL_XOR" => 278,
    "T_MATCH" => 306,
    "T_NAMESPACE" => 342,
    "T_NEW" => 284,
    "T_NS_SEPARATOR" => 402,
    "T_NULLSAFE_OBJECT_OPERATOR" => 389,
    "T_NUM_STRING" => 271,
    "T_OBJECT_OPERATOR" => 388,
    "T_OPEN_TAG" => 393,
    "T_OPEN_TAG_WITH_ECHO" => 394,
    "T_PAAMAYIM_NEKUDOTAYIM" => 401,
    "T_PRINT" => 280,
    "T_PRIVATE" => 324,
    "T_PROTECTED" => 325,
    "T_PUBLIC" => 326,
    "T_READONLY" => 330,
    "T_RETURN" => 313,
    "T_SL" => 377,
    "T_SPACESHIP" => 376,
    "T_SR" => 378,
    "T_STATIC" => 321,
    "T_STRING" => 262,
    "T_SWITCH" => 302,
    "T_THROW" => 317,
    "T_TRAIT" => 337,
    "T_TRY" => 314,
    "T_UNSET" => 332,
    "T_USE" => 318,
    "T_VAR" => 331,
    "T_VARIABLE" => 266,
    "T_WHILE" => 293,
    "T_WHITESPACE" => 396,
    "T_YIELD" => 281,
    "T_YIELD_FROM" => 282
  }

  defp token_name_v(vals, i) do
    case vals do
      [{:int, id} | _] ->
        name =
          Enum.find_value(@token_ids, fn {k, v} -> if v == id, do: k end) || "UNKNOWN"

        {:ok, {:string, name}, i}

      _ ->
        {:ok, {:string, "UNKNOWN"}, i}
    end
  end

  defp token_get_all_v(vals, i) do
    case vals do
      [{:string, src} | _] ->
        had_open = String.starts_with?(String.trim_leading(src), "<?php")

        toks = PhpBeam.Lexer.tokenize(normalize_php_open(src)) |> elem(1)

        open_rows =
          if had_open do
            [{nil, tok_arr(tok_id("T_OPEN_TAG"), "<?php ", 1)}]
          else
            []
          end

        arr =
          (open_rows ++ Enum.flat_map(toks, &token_row/1)) |> PArray.from_pairs()

        {:ok, {:array, arr}, i}

      _ ->
        {:ok, {:array, PArray.new()}, i}
    end
  end

  defp normalize_php_open("<?php" <> rest), do: "<?php" <> rest
  defp normalize_php_open(src), do: "<?php " <> src

  defp token_row({kind, line, text}) do
    case kind do
      :name ->
        case Map.get(@name_to_token, String.downcase(text)) do
          nil ->
            [{nil, tok_arr(tok_id("T_STRING"), text, line)}]

          token ->
            [{nil, tok_arr(tok_id(token), text, line)}]
        end

      :variable ->
        txt = if String.starts_with?(text, "$"), do: text, else: "$" <> text
        [{nil, tok_arr(tok_id("T_VARIABLE"), txt, line)}]

      :number ->
        [{nil, tok_arr(tok_id("T_LNUMBER"), text, line)}]

      :string ->
        [{nil, tok_arr(tok_id("T_CONSTANT_ENCAPSED_STRING"), text, line)}]

      :whitespace ->
        [{nil, tok_arr(tok_id("T_WHITESPACE"), text, line)}]

      :comment ->
        [{nil, tok_arr(tok_id("T_COMMENT"), text, line)}]

      :ident ->
        [{nil, tok_arr(tok_id("T_STRING"), text, line)}]

      :op ->
        [{nil, {:string, text}}]

      _ ->
        []
    end
  end

  defp tok_arr(id, text, line) do
    {:array,
     PArray.from_pairs([
       {0, {:int, id}},
       {1, {:string, text}},
       {2, {:int, line}}
     ])}
  end

  defp tok_id(token), do: Map.get(@token_ids, token, 0)

  ## ───────────────── filter ─────────────────

  # php constants
  @validate_int 257
  @validate_bool 258
  @validate_float 259
  @validate_regexp 272
  @validate_url 273
  @validate_email 274
  @validate_ip 275
  @validate_domain 277
  @sanitize_number_int 519
  @default 516

  defp filter_var_v(vals, i) do
    case vals do
      [v, {:int, flag} | rest] when is_tuple(v) ->
        opts = filter_opts(rest)
        res = apply_filter(v, flag, opts)
        {:ok, res, i}

      [v, {:string, name} | rest] ->
        case filter_id_by_name(name) do
          nil -> {:ok, {:bool, false}, i}
          flag -> filter_var_v([v, {:int, flag} | rest], i)
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp filter_opts(rest) do
    case rest do
      [{:array, arr} | _] ->
        case PArray.fetch(arr, {:string, "options"}) do
          {:ok, {:array, inner}} -> inner
          _ -> PArray.new()
        end

      _ ->
        PArray.new()
    end
  end

  defp apply_filter({:string, s} = v, flag, opts) do
    case flag do
      @validate_email ->
        if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, s), do: v, else: filter_default(opts)

      @validate_url ->
        if Regex.match?(~r{^[a-z][a-z0-9+.-]*://[^\s]+$}i, s), do: v, else: filter_default(opts)

      @validate_ip ->
        if Regex.match?(~r/^(\d{1,3}\.){3}\d{1,3}$/, s), do: v, else: filter_default(opts)

      @validate_int ->
        trimmed = String.trim(s)

        case Integer.parse(trimmed) do
          {n, ""} ->
            check_range(n, opts)
            |> then(fn ok -> if ok, do: {:int, n}, else: filter_default(opts) end)

          _ ->
            filter_default(opts)
        end

      @validate_float ->
        case Float.parse(String.trim(s)) do
          {f, ""} -> {:float, f}
          _ -> filter_default(opts)
        end

      @validate_bool ->
        case String.downcase(s) do
          x when x in ["1", "true", "on", "yes"] -> {:bool, true}
          x when x in ["0", "false", "off", "no", ""] -> {:bool, false}
          _ -> filter_default(opts)
        end

      @validate_domain ->
        if Regex.match?(~r/^([a-z0-9](-*[a-z0-9])*\.)+[a-z]{2,}$/i, s),
          do: v,
          else: filter_default(opts)

      @sanitize_number_int ->
        kept = Regex.replace(~r/[^0-9+-]/, s, "")
        {:string, kept}

      _ ->
        v
    end
  end

  defp apply_filter(v, _flag, _opts), do: v

  defp check_range(n, opts) do
    min = opt_int(opts, "min_range")
    max = opt_int(opts, "max_range")
    (min == nil or n >= min) and (max == nil or n <= max)
  end

  defp opt_int(opts, key) do
    case PArray.fetch(opts, {:string, key}) do
      {:ok, {:int, n}} -> n
      _ -> nil
    end
  end

  defp filter_default(opts) do
    case PArray.fetch(opts, {:string, "default"}) do
      {:ok, v} -> v
      _ -> {:bool, false}
    end
  end

  defp filter_has_var_v(_vals, i), do: {:ok, {:bool, false}, i}

  defp filter_input_v(vals, i) do
    case vals do
      [{:int, _type}, {:string, name} | _] ->
        # CLI: no INPUT superglobals seeded → php returns null (probed
        # filter_has_var false; input returns null w/o FILTER_NULL_ON_FAIL)
        _ = name
        {:ok, :null, i}

      _ ->
        {:ok, :null, i}
    end
  end

  defp filter_list_v(_vals, i) do
    names =
      ~w(int boolean float validate_regexp validate_url validate_email validate_ip validate_domain string stripped encoded special_chars unsafe_raw email url number_int number_float magic_quotes callback)

    arr = names |> Enum.with_index(fn n, idx -> {idx, {:string, n}} end) |> PArray.from_pairs()
    {:ok, {:array, arr}, i}
  end

  defp filter_id_v(vals, i) do
    case vals do
      [{:string, name} | _] ->
        {:ok, {:int, filter_id_by_name(name) || 0}, i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp filter_id_by_name(name) do
    case name do
      "int" -> @validate_int
      "boolean" -> @validate_bool
      "float" -> @validate_float
      "validate_regexp" -> @validate_regexp
      "validate_url" -> @validate_url
      "validate_email" -> @validate_email
      "validate_ip" -> @validate_ip
      "validate_domain" -> @validate_domain
      "number_int" -> @sanitize_number_int
      _ -> nil
    end
  end

  defp filter_var_array_v(vals, i) do
    case vals do
      [{:array, arr} | _] ->
        out =
          Enum.map(PArray.to_pairs(arr), fn {k, v} ->
            {k, filter_var_v([v, {:int, @validate_int}], i) |> elem(1)}
          end)

        {:ok, {:array, PArray.from_pairs(out)}, i}

      _ ->
        {:ok, {:array, PArray.new()}, i}
    end
  end

  defp filter_input_array_v(_vals, i), do: {:ok, :null, i}

  ## ───────────────── Core misc ─────────────────

  defp strncasecmp_v(vals, i) do
    case vals do
      [{:string, a}, {:string, b}, {:int, n} | _] ->
        ah = String.downcase(binary_part(a, 0, min(n, byte_size(a))))
        bh = String.downcase(binary_part(b, 0, min(n, byte_size(b))))

        cond do
          ah < bh -> {:ok, {:int, -1}, i}
          ah > bh -> {:ok, {:int, 1}, i}
          true -> {:ok, {:int, 0}, i}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp class_alias_v(vals, i) do
    case vals do
      [{:string, original}, {:string, alias} | _] ->
        key = String.downcase(original)

        case PhpBeam.Classes.Table.get_class(i, key) do
          nil ->
            warn_throw(
              "class_alias(): Cannot declare class #{alias} because the name is already in use",
              i
            )

          klass ->
            aliased = %{klass | name: alias}
            i2 = %{i | classes: Map.put(i.classes, String.downcase(alias), aliased)}
            {:ok, {:bool, true}, i2}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp get_called_class_v(_vals, i), do: {:ok, {:bool, false}, i}

  defp get_class_vars_v(vals, i) do
    case vals do
      [{:string, cls} | _] ->
        key = String.downcase(cls)

        defaults =
          chain(i, key)
          |> Enum.reverse()
          |> Enum.flat_map(fn k ->
            case PhpBeam.Classes.Table.get_class(i, k) do
              %{props: ps} -> ps
              _ -> []
            end
          end)

        arr =
          PArray.from_pairs(
            Enum.map(defaults, fn p ->
              {p.name, Map.get(p, :default, :null)}
            end)
          )

        {:ok, {:array, arr}, i}

      _ ->
        {:ok, {:array, PArray.new()}, i}
    end
  end

  defp mangled_vars_v(vals, i) do
    case vals do
      [{:object, _} = oref | _] ->
        obj = Eval.get_object(i, oref)
        arr = obj.props
        {:ok, {:array, arr}, i}

      _ ->
        {:ok, {:array, PArray.new()}, i}
    end
  end

  defp trait_exists_v(vals, i) do
    case vals do
      [{:string, name} | _] ->
        found =
          case PhpBeam.Classes.Table.get_class(i, String.downcase(name)) do
            %{kind: :trait} -> true
            _ -> false
          end

        {:ok, {:bool, found}, i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp enum_exists_v(vals, i) do
    case vals do
      [{:string, name} | _] ->
        found =
          case PhpBeam.Classes.Table.get_class(i, String.downcase(name)) do
            %{kind: :enum} -> true
            _ -> false
          end

        {:ok, {:bool, found}, i}

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp chain(i, key) do
    case PhpBeam.Classes.Table.get_class(i, key) do
      %{parent: p} when not is_nil(p) -> [key | chain(i, p)]
      _ -> [key]
    end
  end

  defp included_files_v(_vals, i) do
    arr =
      Map.keys(i.included || %{})
      |> Enum.with_index(fn f, idx -> {idx, {:string, f}} end)
      |> PArray.from_pairs()

    {:ok, {:array, arr}, i}
  end

  defp declared_classes_v(_vals, i) do
    arr =
      i.classes
      |> Enum.filter(fn {_k, c} -> Map.get(c, :kind) == :class end)
      |> Enum.map(fn {_k, c} -> c.name end)
      |> Enum.sort()
      |> Enum.with_index(fn n, idx -> {idx, {:string, n}} end)
      |> PArray.from_pairs()

    {:ok, {:array, arr}, i}
  end

  defp declared_interfaces_v(_vals, i) do
    arr =
      i.classes
      |> Enum.filter(fn {_k, c} -> Map.get(c, :kind) == :interface end)
      |> Enum.map(fn {_k, c} -> c.name end)
      |> Enum.sort()
      |> Enum.with_index(fn n, idx -> {idx, {:string, n}} end)
      |> PArray.from_pairs()

    {:ok, {:array, arr}, i}
  end

  defp declared_traits_v(_vals, i) do
    arr =
      i.classes
      |> Enum.filter(fn {_k, c} -> Map.get(c, :kind) == :trait end)
      |> Enum.map(fn {_k, c} -> c.name end)
      |> Enum.sort()
      |> Enum.with_index(fn n, idx -> {idx, {:string, n}} end)
      |> PArray.from_pairs()

    {:ok, {:array, arr}, i}
  end

  defp defined_vars_v(_vals, i) do
    # CLI top-level: only superglobals (php defines them in get_defined_vars)
    arr =
      ~w(_SERVER _GET _POST _COOKIE _FILES _REQUEST _ENV)
      |> Enum.with_index(fn n, idx -> {idx, {:string, n}} end)
      |> PArray.from_pairs()

    {:ok, {:array, arr}, i}
  end

  defp resource_id_v(vals, i) do
    case vals do
      [{:resource, id} | _] -> {:ok, {:int, id}, i}
      _ -> {:ok, {:bool, false}, i}
    end
  end

  defp get_resources_v(_vals, i) do
    arr =
      i.resources
      |> Enum.filter(fn {_k, r} -> Map.get(r, :closed) == false end)
      |> Enum.map(fn {id, _} -> {{:int, id}, :null} end)
      |> PArray.from_pairs()

    {:ok, {:array, arr}, i}
  end

  defp loaded_extensions_v(_vals, i) do
    exts =
      ~w(Core standard date mbstring ctype iconv json hash pcre filter tokenizer session spl reflection openssl curl zlib zip ftp posix random calendar bcmath gmp)

    arr = exts |> Enum.with_index(fn n, idx -> {idx, {:string, n}} end) |> PArray.from_pairs()
    {:ok, {:array, arr}, i}
  end

  defp defined_constants_v(_vals, i) do
    arr =
      i.consts
      |> Enum.map(fn {k, v} -> {k, v} end)
      |> PArray.from_pairs()

    {:ok, {:array, arr}, i}
  end

  defp debug_backtrace_v(_vals, i) do
    # renders like php's default (array dump would need frames; V1 minimal)
    {:ok, :null, i}
  end

  defp gc_mem_caches_v(_vals, i), do: {:ok, {:int, 0}, i}
  defp gc_enabled_v(_vals, i), do: {:ok, {:bool, true}, i}
  defp gc_nop_v(_vals, i), do: {:ok, :null, i}

  defp gc_status_v(_vals, i) do
    arr =
      PArray.from_pairs([
        {"runs", {:int, 0}},
        {"collected", {:int, 0}},
        {"threshold", {:int, 10_001}},
        {"roots", {:int, 0}}
      ])

    {:ok, {:array, arr}, i}
  end

  defp user_error_v(vals, i) do
    {:ok, {:bool, true},
     case Eval.Error.warn(
            Eval.Error.stub_env(),
            i,
            vals |> Enum.at(0, {:string, ""}) |> Eval.php_to_string()
          ) do
       {:cont, _, i2} -> i2
       {:unwind, _, _, i2} -> i2
     end}
  end

  defp extension_funcs_v(vals, i) do
    case vals do
      [{:string, ext} | _] ->
        names =
          i.functions
          |> Enum.filter(fn {_n, entry} ->
            Map.has_key?(entry, :domain) and entry.domain == ext
          end)
          |> Enum.map(fn {n, _} -> n end)

        arr =
          names |> Enum.with_index(fn n, idx -> {idx, {:string, n}} end) |> PArray.from_pairs()

        {:ok, {:array, arr}, i}

      _ ->
        {:ok, {:array, PArray.new()}, i}
    end
  end

  ## ───────────────── spl info ─────────────────

  defp spl_classes_v(_vals, i) do
    arr =
      i.classes
      |> Enum.filter(fn {_k, c} -> Map.get(c, :kind) in [:class, :interface] end)
      |> Enum.map(fn {_k, c} -> {c.name, {:string, c.name}} end)
      |> PArray.from_pairs()

    {:ok, {:array, arr}, i}
  end

  defp class_parents_v(vals, i) do
    case vals do
      [{:string, cls} | _] ->
        chain(i, String.downcase(cls))
        |> tl()
        |> Enum.map(&PhpBeam.Classes.Table.get_class(i, &1))
        |> Enum.map(& &1.name)
        |> Enum.with_index(fn n, idx -> {idx, {:string, n}} end)
        |> PArray.from_pairs()
        |> then(fn arr -> {:ok, {:array, arr}, i} end)

      _ ->
        {:ok, {:array, PArray.new()}, i}
    end
  end

  defp class_implements_v(vals, i) do
    case vals do
      [{:string, cls} | _] ->
        ifaces =
          chain(i, String.downcase(cls))
          |> Enum.flat_map(fn k -> iface_closure(i, k) end)
          |> Enum.uniq()
          |> Enum.map(fn k ->
            name =
              case PhpBeam.Classes.Table.get_class(i, k) do
                %{name: n} -> n
                _ -> k
              end

            {name, {:string, name}}
          end)

        arr = PArray.from_pairs(ifaces)

        {:ok, {:array, arr}, i}

      _ ->
        {:ok, {:array, PArray.new()}, i}
    end
  end

  # transitive: IteratorAggregate implies Traversable, etc.
  defp iface_closure(i, key, seen \\ MapSet.new()) do
    if MapSet.member?(seen, key) do
      []
    else
      case PhpBeam.Classes.Table.get_class(i, key) do
        %{interfaces: ifaces} ->
          seen2 = MapSet.put(seen, key)
          own = ifaces -- ["#{key}"]

          Enum.flat_map(own, fn ik -> [ik | iface_closure(i, ik, seen2)] end)

        _ ->
          []
      end
    end
  end

  defp class_uses_v(_vals, i), do: {:ok, {:array, PArray.new()}, i}

  defp spl_autoload_extensions_v(vals, i) do
    case vals do
      [{:string, _exts} | _] -> {:ok, {:bool, true}, i}
      _ -> {:ok, {:string, ".inc,.php"}, i}
    end
  end

  defp spl_autoload_fns_v(vals, i) do
    arr = i.autoload_fns |> Enum.with_index(fn f, idx -> {idx, f} end) |> PArray.from_pairs()
    _ = vals
    {:ok, {:array, arr}, i}
  end

  defp spl_autoload_v(vals, i) do
    case vals do
      [{:string, name} | _] ->
        {klass, i2} = Eval.fetch_class(i, String.downcase(name), name)

        if klass do
          {:ok, {:bool, true}, i2}
        else
          {:ok, {{:bool, false}, nil}, i2}
        end

      _ ->
        {:ok, {:bool, false}, i}
    end
  end

  defp iterator_to_array_v(vals, i) do
    case vals do
      [{:object, _} = oref | _] ->
        obj = Eval.get_object(i, oref)

        arr =
          case obj.dt_state && obj.dt_state["arr"] do
            %PArray{} = inner ->
              inner

            _ ->
              obj.props
          end

        {:ok, {:array, arr}, i}

      _ ->
        {:ok, {:array, PArray.new()}, i}
    end
  end

  defp iterator_count_v(vals, i) do
    case vals do
      [{:object, _} = oref | _] ->
        obj = Eval.get_object(i, oref)

        n =
          case obj.dt_state && obj.dt_state["arr"] do
            %PArray{} = inner -> PArray.size(inner)
            _ -> PArray.size(obj.props)
          end

        {:ok, {:int, n}, i}

      _ ->
        {:ok, {:int, 0}, i}
    end
  end

  defp iterator_apply_stub(vals, i) do
    _ = vals
    {:ok, {:int, 0}, i}
  end

  ## ───────────────── session ─────────────────

  defp session_status_v(_vals, i) do
    # 1 = PHP_SESSION_NONE (no active session in CLI single-shot)
    _ = i
    {:ok, {:int, 1}, i}
  end

  defp session_name_v(vals, i) do
    case vals do
      [{:string, n} | _] ->
        {:ok, {{:string, "PHPSESSID"}, i}, %{i | ini: Map.put(i.ini, "session.name", n)}}

      _ ->
        {:ok, {:string, Map.get(i.ini, "session.name", "PHPSESSID")}, i}
    end
  end

  defp session_module_v(vals, i) do
    case vals do
      [{:string, _} | _] -> {:ok, {:bool, true}, i}
      _ -> {:ok, {:string, "files"}, i}
    end
  end

  defp session_save_path_v(vals, i) do
    case vals do
      [{:string, p} | _] ->
        {:ok, {{:string, ""}, i}, %{i | ini: Map.put(i.ini, "session.save_path", p)}}

      _ ->
        {:ok, {:string, Map.get(i.ini, "session.save_path", "")}, i}
    end
  end

  defp session_id_v(vals, i) do
    case vals do
      [{:string, new} | _] ->
        {:ok, {{:string, ""}, i}, %{i | ini: Map.put(i.ini, "phpbeam.session_id", new)}}

      _ ->
        {:ok, {:string, Map.get(i.ini, "phpbeam.session_id", "")}, i}
    end
  end

  defp session_cache_limiter_v(vals, i) do
    case vals do
      [{:string, _} | _] -> {:ok, {:bool, true}, i}
      _ -> {:ok, {:string, "nocache"}, i}
    end
  end

  defp session_cache_expire_v(vals, i) do
    case vals do
      [{:int, n} | _] ->
        {:ok, {{:int, 180}, i},
         %{i | ini: Map.put(i.ini, "session.cache_expire", Integer.to_string(n))}}

      _ ->
        {:ok, {:int, String.to_integer(Map.get(i.ini, "session.cache_expire", "180"))}, i}
    end
  end

  defp session_cookie_params_v(vals, i) do
    arr =
      PArray.from_pairs([
        {"lifetime", {:int, 0}},
        {"path", {:string, "/"}},
        {"domain", {:string, ""}},
        {"secure", {:bool, false}},
        {"httponly", {:bool, false}},
        {"samesite", {:string, ""}}
      ])

    _ = vals
    {:ok, {:array, arr}, i}
  end

  defp session_set_cookie_v(_vals, i), do: {:ok, {:bool, true}, i}

  defp session_unset_v(_vals, i) do
    i2 = %{i | globals: Map.put(i.globals, "_SESSION", {:array, PArray.new()})}
    {:ok, {:bool, true}, i2}
  end

  defp session_destroy_v(_vals, i), do: {:ok, {:bool, true}, i}
  defp session_write_close_v(_vals, i), do: {:ok, {:bool, true}, i}
  defp session_reset_v(_vals, i), do: {:ok, {:bool, true}, i}
  defp session_gc_v(_vals, i), do: {:ok, {:int, 0}, i}

  defp session_create_id_v(_vals, i) do
    id = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    {:ok, {:string, id}, i}
  end

  defp session_regenerate_v(vals, i) do
    case vals do
      [{:bool, true} | _] ->
        session_create_id_v(vals, i)
        |> then(fn {:ok, {:string, id}, _} -> {:ok, {:string, id}, i} end)

      _ ->
        {:ok, {:bool, true}, i}
    end
  end

  defp session_reg_shutdown_v(_vals, i), do: {:ok, :null, i}

  defp session_set_save_handler_v(vals, i) do
    # registers the handler; V1 storage-only (session_start is the stub gate)
    _ = vals
    {:ok, {:bool, true}, i}
  end

  defp session_encode_v(_vals, i), do: {:ok, {:bool, false}, i}
  defp session_decode_v(_vals, i), do: {:ok, {:bool, false}, i}

  defp session_start_v(vals, i) do
    _ = vals
    # $_SESSION already seeded as empty array by Env; php CLI without
    # session.save_path returns true with $_SESSION usable
    i2 = %{i | globals: Map.put(i.globals, "_SESSION", {:array, PArray.new()})}
    {:ok, {:bool, true}, i2}
  end
end

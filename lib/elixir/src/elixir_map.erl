-module(elixir_map).
-export([expand_map/3, translate_map/3, expand_struct/4, translate_struct/4]).
-import(elixir_errors, [compile_error/4]).
-include("elixir.hrl").

expand_map(Meta, [{ '|', UpdateMeta, [Left, Right]}], E) ->
  { [ELeft|ERight], EA } = elixir_exp:expand_args([Left|Right], E),
  { { '%{}', Meta, [{ '|', UpdateMeta, [ELeft, ERight] }] }, EA };
expand_map(Meta, Args, E) ->
  { EArgs, EA } = elixir_exp:expand_args(Args, E),
  { { '%{}', Meta, EArgs }, EA }.

expand_struct(Meta, Left, Right, E) ->
  { [ELeft, ERight], EE } = elixir_exp:expand_args([Left, Right], E),

  case is_atom(ELeft) of
    true  -> ok;
    false ->
      compile_error(Meta, E#elixir_env.file, "expected struct name to be a compile "
        "time atom or alias, got: ~ts", ['Elixir.Macro':to_string(ELeft)])
  end,

  EMeta =
    case lists:member(ELeft, E#elixir_env.context_modules) andalso
         elixir_module:is_open(ELeft) of
      true  -> [{ struct, context }|Meta];
      false -> elixir_aliases:ensure_loaded(Meta, ELeft, E), Meta
    end,

  case ERight of
    { '%{}', _, _ } -> ok;
    _ -> compile_error(Meta, E#elixir_env.file,
           "expected struct to be followed by a map, got: ~ts",
           ['Elixir.Macro':to_string(ERight)])
  end,

  { { '%', EMeta, [ELeft, ERight] }, EE }.

translate_map(Meta, Args, S) ->
  { Assocs, TUpdate, US } = extract_assoc_update(Args, S),
  translate_map(Meta, Assocs, TUpdate, US).

translate_struct(Meta, Name, { '%{}', MapMeta, Args }, S) ->
  { Assocs, TUpdate, US } = extract_assoc_update(Args, S),

  Struct = case lists:keyfind(struct, 1, Meta) of
    { struct, context } -> (elixir_locals:local_for(Name, '__struct__', 0, def))();
    _ -> Name:'__struct__'()
  end,

  case is_map(Struct) of
    true  ->
      assert_struct_keys(Meta, Name, Struct, Assocs, S);
    false ->
      compile_error(Meta, S#elixir_scope.file, "expected ~ts.__struct__/0 to "
        "return a map, got: ~ts", [elixir_aliases:inspect(Name), 'Elixir.Kernel':inspect(Struct)])
  end,

  case TUpdate of
    nil ->
      StructAssocs =
        case S#elixir_scope.context of
          match ->
            [{'__struct__', Name}|Assocs];
          _ ->
            maps:to_list(maps:put('__struct__', Name,
              maps:merge(Struct, maps:from_list(Assocs))))
        end,
      translate_map(MapMeta, StructAssocs, nil, US);
    _ ->
      Line  = ?line(Meta),
      { VarName, _, VS } = elixir_scope:build_var('_', US),

      Var = { var, Line, VarName },
      Map = { map, Line, [{ map_field_exact, Line, { atom, Line, '__struct__' }, { atom, Line, Name }}] },

      Match = { match, Line, Var, Map },
      Error = { tuple, Line, [{ atom, Line, badstruct }, { atom, Line, Name }, Var] },

      { TMap, TS } = translate_map(MapMeta, Assocs, Var, VS),

      { { 'case', Line, TUpdate, [
        { clause, Line, [Match], [], [TMap] },
        { clause, Line, [Var], [], [?wrap_call(Line, erlang, error, [Error])] }
      ] }, TS }
  end.

%% Helpers

translate_map(Meta, Assocs, TUpdate, #elixir_scope{extra=Extra} = S) ->
  { Op, KeyFun, ValFun } = extract_key_val_op(TUpdate, S),

  Line = ?line(Meta),

  { TArgs, SA } = lists:mapfoldl(fun
    ({ Key, Value }, Acc) ->
      { TKey, Acc1 }   = KeyFun(Key, Acc),
      { TValue, Acc2 } = ValFun(Value, Acc1#elixir_scope{extra=Extra}),
      { { Op, ?line(Meta), TKey, TValue }, Acc2 };
    (Other, _Acc) ->
      compile_error(Meta, S#elixir_scope.file, "expected key-value pairs in map, got: ~ts",
                     ['Elixir.Macro':to_string(Other)])
  end, S, Assocs),

  build_map(Line, TUpdate, TArgs, SA).

extract_assoc_update([{ '|', _Meta, [Update, Args] }], S) ->
  { TArg, SA } = elixir_translator:translate_arg(Update, S, S),
  { Args, TArg, SA };
extract_assoc_update(Args, SA) -> { Args, nil, SA }.

extract_key_val_op(_TUpdate, #elixir_scope{context=match}) ->
  { map_field_exact,
    fun(X, Acc) -> elixir_translator:translate(X, Acc#elixir_scope{extra=map_key}) end,
    fun elixir_translator:translate/2 };
extract_key_val_op(TUpdate, S) ->
  KS = #elixir_scope{extra=map_key},
  Op = if TUpdate == nil -> map_field_assoc; true -> map_field_exact end,
  { Op,
    fun(X, Acc) -> elixir_translator:translate_arg(X, Acc, KS) end,
    fun(X, Acc) -> elixir_translator:translate_arg(X, Acc, S) end }.

build_map(Line, nil, TArgs, SA) -> { { map, Line, TArgs }, SA };
build_map(Line, TUpdate, TArgs, SA) -> { { map, Line, TUpdate, TArgs }, SA }.

assert_struct_keys(Meta, Name, Struct, Assocs, S) ->
  [begin
     compile_error(Meta, S#elixir_scope.file, "unknown key ~ts for struct ~ts",
                   ['Elixir.Kernel':inspect(Key), elixir_aliases:inspect(Name)])
   end || { Key, _ } <- Assocs, not maps:is_key(Key, Struct)].

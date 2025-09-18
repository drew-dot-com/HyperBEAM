%% DETS + ETS-backed scheduler location store with TTL
%% Key: Address (binary)  Value: {Url(binary), ExpiresMs(integer)}

-module(hb_sched_loc).
-export([init/0, close/0, get/1, put/3, delete/1]).

-define(TBL, ?MODULE).
-define(DETS, hb_sched_loc_dets).

%% ===== Public API =====

init() ->
    ok = ensure_state_dir(),
    {ok, _} = dets:open_file(?DETS, [{type, set}, {file, dets_path()}, {auto_save, 5000}]),
    (catch ets:new(?TBL, [named_table, public, set, {read_concurrency, true}])),
    load_valid_into_ets(),
    ok.

close() ->
    (catch dets:sync(?DETS)),
    (catch dets:close(?DETS)),
    ok.

get(Addr0) ->
    Addr = to_bin(Addr0),
    Now = now_ms(),
    case ets:lookup(?TBL, Addr) of
        [{_, Url, Exp}] when Exp > Now -> {Url, Exp};
        [{_, _Url, _Exp}] ->
            ets:delete(?TBL, Addr), dets:delete(?DETS, Addr), undefined;
        [] ->
            case dets:lookup(?DETS, Addr) of
                [{_, Url2, Exp2}] when Exp2 > Now ->
                    ets:insert(?TBL, {Addr, Url2, Exp2}),
                    {Url2, Exp2};
                [{_, _Url2, _Exp2}] ->
                    dets:delete(?DETS, Addr), undefined;
                _ -> undefined
            end
    end.

put(Addr0, Url0, Exp) when is_integer(Exp) ->
    Addr = to_bin(Addr0),
    Url  = to_bin(Url0),
    ets:insert(?TBL, {Addr, Url, Exp}),
    ok = dets:insert(?DETS, {Addr, Url, Exp}),
    ok = dets:sync(?DETS),
    ok.

delete(Addr0) ->
    Addr = to_bin(Addr0),
    ets:delete(?TBL, Addr),
    dets:delete(?DETS, Addr),
    ok.

%% ===== Helpers =====

load_valid_into_ets() ->
    Now = now_ms(),
    Fold = fun({A,U,E}, Acc) ->
               case E > Now of
                   true  -> ets:insert(?TBL, {A,U,E}), Acc;
                   false -> dets:delete(?DETS, A), Acc
               end
           end,
    dets:foldl(Fold, ok, ?DETS),
    ok.

ensure_state_dir() ->
    Dir = state_dir(),
    case filelib:ensure_dir(filename:join(Dir, "x")) of
        ok -> ok;
        {error, eexist} -> ok;
        Error -> error_logger:error_msg("Failed to ensure state dir ~p: ~p", [Dir, Error]), Error
    end.

state_dir() ->
    %% Allow override via env HB_STATE_DIR, fallback to /var/lib/hb
    case os:getenv("HB_STATE_DIR") of
        false -> "/var/lib/hb";
        Dir   -> Dir
    end.

dets_path() -> filename:join(state_dir(), "sched_loc.dets").

to_bin(B) when is_binary(B) -> B;
 to_bin(<<>>) -> <<>>;
 to_bin(undefined) -> <<>>;
 to_bin(L) when is_list(L)   -> list_to_binary(L).

now_ms() -> erlang:system_time(millisecond).

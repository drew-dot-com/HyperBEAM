-module(hb_sched_loc).
-export([init/0, get/1, put/3]).

%% Simple ETS-backed store for scheduler locations with TTL (ms).
%% Key: Address (binary). Value: {Url :: binary(), ExpiryMs :: integer()}.

init() ->
    case ets:info(?MODULE) of
        undefined -> (catch ets:new(?MODULE, [named_table, public, set, {read_concurrency, true}])), ok;
        _ -> ok
    end.

get(undefined) -> undefined;
get(<<>>) -> undefined;
get(Addr) when is_binary(Addr) ->
    Now = erlang:system_time(millisecond),
    case ets:lookup(?MODULE, Addr) of
        [{_, Url, Exp}] when is_integer(Exp), Exp > Now -> {Url, Exp};
        [{_, _, _}] -> ets:delete(?MODULE, Addr), undefined;
        [] -> undefined
    end.

put(Addr, Url, Exp) when is_binary(Addr), is_binary(Url), is_integer(Exp) ->
    ets:insert(?MODULE, {Addr, Url, Exp}), ok.


%%% @doc Persistent scheduler-location store backed by the node's primary store.
-module(hb_sched_loc_store).
-export([init/0, get/1, get_meta/1, put/2, maybe_seed/2, record_location/2, local_url/0, self_addresses/0]).

-compile({no_auto_import,[get/1, put/2]}).

-include("include/hb.hrl").

-define(TABLE, hb_sched_loc_store).
-define(STORE_KEY, {hb_sched_loc_store, store}).
-define(STORE_ROOT, [<<"~scheduler@1.0">>, <<"location-map">>]).

%% @doc Ensure ETS table exists and preload persisted entries.
init() ->
    ensure_table(),
    maybe_load_from_store(),
    maybe_seed_self(),
    ok.

%% @doc Return the URL this node advertises for scheduling.
local_url() ->
    Proto = case hb_opts:get(protocol, http1) of
        http1 -> <<"http">>;
        https -> <<"https">>;
        http2 -> <<"https">>;
        _ -> <<"http">>
    end,
    Host = hb_opts:get(host, <<"127.0.0.1">>),
    Port = hb_util:bin(hb_opts:get(port, 8734)),
    <<Proto/binary, "://", Host/binary, ":", Port/binary>>.

%% @doc Return identifiers that should resolve to this node.
self_addresses() ->
    Wallet = hb:wallet(),
    Addr = hb:address(Wallet),
    Pub = hb_util:encode(ar_wallet:to_pubkey(Wallet)),
    [Addr, <<"publickey:", Pub/binary>>].

%% @doc Look up a scheduler location by address.
get(Address) ->
    ensure_table(),
    Key = normalize_address(Address),
    case ets:lookup(?TABLE, Key) of
        [{Key, Url}] -> {ok, Url};
        [] ->
            case read_entry(Key) of
                {ok, Url} ->
                    ets:insert(?TABLE, {Key, Url}),
                    {ok, Url};
                not_found -> not_found
            end
    end.
get_meta(Address) ->
    ensure_table(),
    read_meta(normalize_address(Address)).


%% @doc Persist a scheduler location mapping.
put(Address, Url) ->
    ensure_table(),
    Value = normalize_url(Url),
    lists:foreach(fun(Key) -> store_address(Key, Value) end, expand_addresses(Address)),
    ok.

%% @doc Store the mapping if it is not already recorded or differs.
maybe_seed(Address, Url) ->
    ensure_table(),
    Value = normalize_url(Url),
    lists:foreach(
        fun(Key) ->
            case get(Key) of
                {ok, Existing} when Existing =:= Value -> ok;
                _ -> store_address(Key, Value)
            end
        end,
        expand_addresses(Address)
    ).

%% @doc Record scheduler-location message (signed) to the store.
record_location(LocationMsg, Opts) ->
    case location_url(LocationMsg, Opts) of
        not_found -> ok;
        Url ->
            Signers = hb_message:signers(LocationMsg, Opts),
            lists:foreach(fun(Address) -> maybe_seed(Address, Url) end, Signers)
    end.

%% Internal helpers.

ensure_table() ->
    case ets:info(?TABLE) of
        undefined ->
            ets:new(?TABLE, [named_table, set, public, {read_concurrency, true}, {write_concurrency, true}]);
        _ -> ok
    end.

store_opts() ->
    case persistent_term:get(?STORE_KEY, undefined) of
        undefined ->
            Store = hb_opts:get(store, []),
            hb_store:start(Store),
            persistent_term:put(?STORE_KEY, Store),
            Store;
        Store -> Store
    end.

maybe_load_from_store() ->
    case persistent_term:get({hb_sched_loc_store, loaded}, undefined) of
        undefined ->
            lists:foreach(fun load_entry/1, list_addresses()),
            persistent_term:put({hb_sched_loc_store, loaded}, true);
        _ -> ok
    end.

list_addresses() ->
    case hb_store:list(store_opts(), ?STORE_ROOT) of
        {ok, Items} -> Items;
        not_found -> []
    end.

load_entry(Address) ->
    case read_entry(Address) of
        {ok, Url} -> ets:insert(?TABLE, {normalize_address(Address), Url});
        _ -> ok
    end.

read_entry(Address) ->
    case read_meta(Address) of
        {ok, Meta} ->
            case meta_url(Meta) of
                undefined -> not_found;
                Url -> {ok, Url}
            end;
        Other -> Other
    end.

read_meta(Address) ->
    case hb_store:read(store_opts(), ?STORE_ROOT ++ [normalize_address(Address)]) of
        {ok, Data} -> decode_meta(Data);
        not_found -> not_found;
        {error, _}=Err -> Err
    end.

meta_url(Meta) when is_map(Meta) ->
    case maps:get(url, Meta, undefined) of
        undefined -> undefined;
        Url -> normalize_url(Url)
    end;
meta_url(_) -> undefined.

decode_meta(Data) when is_binary(Data) ->
    case try_decode_term(Data) of
        {ok, Term} ->
            case normalize_meta_term(Term) of
                {ok, Meta} -> ensure_url_meta(Meta, Data);
                error -> fallback_meta(Data)
            end;
        error -> fallback_meta(Data)
    end;
decode_meta(Data) ->
    fallback_meta(Data).

try_decode_term(Data) ->
    try {ok, binary_to_term(Data)}
    catch _:_ -> error
    end.

normalize_meta_term(Term) when is_map(Term) ->
    Url = get_any(Term, [url, <<"url">>]),
    TTL = get_any(Term, [ttl, <<"ttl">>]),
    Ts = get_any(Term, [ts, <<"ts">>, timestamp, <<"timestamp">>]),
    Meta0 = #{},
    Meta1 = maybe_put_meta(Meta0, url, maybe_normalize_url(Url)),
    Meta2 = maybe_put_meta(Meta1, ttl, maybe_normalize_int(TTL)),
    Meta3 = maybe_put_meta(Meta2, ts, maybe_normalize_int(Ts)),
    {ok, Meta3};
normalize_meta_term(_) ->
    error.

maybe_put_meta(Map, _Key, undefined) -> Map;
maybe_put_meta(Map, Key, Value) -> Map#{Key => Value}.

get_any(_, []) -> undefined;
get_any(Map, [Key | Rest]) ->
    case maps:find(Key, Map) of
        {ok, Value} -> Value;
        error -> get_any(Map, Rest)
    end.

maybe_normalize_url(undefined) -> undefined;
maybe_normalize_url(Value) when is_binary(Value); is_list(Value) ->
    normalize_url(Value);
maybe_normalize_url(_) -> undefined.

maybe_normalize_int(undefined) -> undefined;
maybe_normalize_int(Value) when is_integer(Value) -> Value;
maybe_normalize_int(Value) when is_binary(Value); is_list(Value) ->
    try hb_util:int(Value)
    catch _:_ -> undefined
    end;
maybe_normalize_int(_) -> undefined.

ensure_url_meta(Meta, Data) ->
    case maps:get(url, Meta, undefined) of
        undefined -> fallback_meta(Data);
        _ -> {ok, Meta}
    end.

fallback_meta(Data) ->
    case maybe_normalize_url(Data) of
        undefined -> not_found;
        Url -> {ok, #{url => Url}}
    end.

persist(Address, Url) ->
    ok = hb_store:write(store_opts(), ?STORE_ROOT ++ [normalize_address(Address)], term_to_binary(#{ url => Url, ts => erlang:system_time(millisecond) })).

maybe_seed_self() ->
    Url = local_url(),
    ConfigAddresses = collect_addresses(hb_opts:get(scheduler, [])),
    All = lists:usort(self_addresses() ++ ConfigAddresses),
    lists:foreach(fun(Address) -> maybe_seed(Address, Url) end, All).

store_address(Address, Url) ->
    Key = normalize_address(Address),
    persist(Key, Url),
    ets:insert(?TABLE, {Key, Url}).

expand_addresses(Address) ->
    Norm = normalize_address(Address),
    case is_publickey_alias(Norm) of
        true ->
            Base = strip_publickey_prefix(Norm),
            filter_non_empty([Norm, Base]);
        false ->
            Alias = add_publickey_prefix(Norm),
            filter_non_empty([Norm, Alias])
    end.

collect_addresses(Value) when is_binary(Value) ->
    case is_url(Value) of
        true -> [];
        false -> [normalize_address(Value)]
    end;
collect_addresses(Value) when is_list(Value) ->
    lists:flatmap(fun collect_addresses/1, Value);
collect_addresses(Value) when is_map(Value) ->
    case maps:get(<<"address">>, Value, undefined) of
        undefined -> [];
        Addr -> collect_addresses(Addr)
    end;
collect_addresses(_) -> [].

location_url(Msg, Opts) ->
    case hb_ao:get(<<"url">>, Msg, not_found, Opts) of
        not_found -> hb_ao:get(<<"location">>, Msg, not_found, Opts);
        Url -> Url
    end.

normalize_address(Address) when is_binary(Address) -> Address;
normalize_address(Address) -> hb_util:bin(Address).

normalize_url(Url) when is_binary(Url) -> Url;
normalize_url(Url) -> hb_util:bin(Url).

is_publickey_alias(Value) when is_binary(Value) ->
    binary:match(Value, <<"publickey:">>) =:= {0, 10};
is_publickey_alias(Value) when is_list(Value) ->
    is_publickey_alias(hb_util:bin(Value));
is_publickey_alias(_) -> false.

strip_publickey_prefix(Value) when is_binary(Value), byte_size(Value) > 10 ->
    binary:part(Value, 10, byte_size(Value) - 10);
strip_publickey_prefix(_) -> <<>>.

add_publickey_prefix(Value) when is_binary(Value) ->
    case is_base64_like(Value) of
        true -> <<"publickey:", Value/binary>>;
        false -> <<>>
    end;
add_publickey_prefix(Value) when is_list(Value) ->
    add_publickey_prefix(hb_util:bin(Value));
add_publickey_prefix(_) -> <<>>.

is_base64_like(Value) when is_binary(Value) ->
    case re:run(Value, <<"^[A-Za-z0-9_-]{32,}$">>, [{capture, none}]) of
        match -> true;
        nomatch -> false
    end;
is_base64_like(Value) when is_list(Value) ->
    is_base64_like(hb_util:bin(Value));
is_base64_like(_) -> false.

filter_non_empty(List) ->
    lists:usort([Item || Item <- List, is_binary(Item), Item =/= <<>>]).

is_url(Bin) when is_binary(Bin) ->
    case binary:match(Bin, <<"://">>) of
        nomatch -> false;
        _ -> true
    end;
is_url(_) -> false.

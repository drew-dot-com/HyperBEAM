%%% @doc Persistent scheduler-location store backed by the node's primary store.
-module(hb_sched_loc_store).
-export([init/0, get/1, put/2, maybe_seed/2, record_location/2, local_url/0, self_addresses/0]).

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
        [{?TABLE, Key, Url}] -> {ok, Url};
        [] ->
            case read_entry(Key) of
                {ok, Url} ->
                    ets:insert(?TABLE, {?TABLE, Key, Url}),
                    {ok, Url};
                not_found -> not_found
            end
    end.

%% @doc Persist a scheduler location mapping.
put(Address, Url) ->
    ensure_table(),
    Key = normalize_address(Address),
    Value = normalize_url(Url),
    persist(Key, Value),
    ets:insert(?TABLE, {?TABLE, Key, Value}),
    ok.

%% @doc Store the mapping if it is not already recorded or differs.
maybe_seed(Address, Url) ->
    NormUrl = normalize_url(Url),
    case get(Address) of
        {ok, Existing} when Existing =:= NormUrl -> ok;
        _ -> put(Address, NormUrl)
    end.

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
        {ok, Url} -> ets:insert(?TABLE, {?TABLE, normalize_address(Address), Url});
        _ -> ok
    end.

read_entry(Address) ->
    case hb_store:read(store_opts(), ?STORE_ROOT ++ [normalize_address(Address)]) of
        {ok, Data} -> decode_value(Data);
        not_found -> not_found;
        {error, _}=Err -> Err
    end.

persist(Address, Url) ->
    ok = hb_store:write(store_opts(), ?STORE_ROOT ++ [Address], term_to_binary(#{ url => Url, ts => erlang:system_time(millisecond) })).

maybe_seed_self() ->
    Url = local_url(),
    ConfigAddresses = collect_addresses(hb_opts:get(scheduler, [])),
    All = lists:usort(self_addresses() ++ ConfigAddresses),
    lists:foreach(fun(Address) -> maybe_seed(Address, Url) end, All).

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

decode_value(Bin) when is_binary(Bin) ->
    try
        Map = binary_to_term(Bin),
        case Map of
            #{ url := Url } -> {ok, normalize_url(Url)};
            _ -> {ok, normalize_url(Bin)}
        end
    catch _:_ -> {ok, normalize_url(Bin)}
    end;
decode_value(_) -> not_found.

is_url(Bin) when is_binary(Bin) ->
    case binary:match(Bin, <<"://">>) of
        nomatch -> false;
        _ -> true
    end;
is_url(_) -> false.


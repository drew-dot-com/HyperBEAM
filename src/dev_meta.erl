%%% @doc The hyperbeam meta device, which is the default entry point
%%% for all messages processed by the machine. This device executes a
%%% AO-Core singleton request, after first applying the node's 
%%% pre-processor, if set. The pre-processor can halt the request by
%%% returning an error, or return a modified version if it deems necessary --
%%% the result of the pre-processor is used as the request for the AO-Core
%%% resolver. Additionally, a post-processor can be set, which is executed after
%%% the AO-Core resolver has returned a result.
-module(dev_meta).
-export([info/1, info/3, build/3, handle/2, adopt_node_message/2, is/2, is/3]).
-export([is_operator/2]).
-include("include/hb.hrl").
-include_lib("eunit/include/eunit.hrl").
%%% Include the auto-generated build info header file.
-include_lib("../_build/hb_buildinfo.hrl").

%% @doc Ensure that the helper function `adopt_node_message/2' is not exported.
%% The naming of this method carefully avoids a clash with the exported `info/3'
%% function. We would like the node information to be easily accessible via the
%% `info' endpoint, but AO-Core also uses `info' as the name of the function
%% that grants device information. The device call takes two or fewer arguments,
%% so we are safe to use the name for both purposes in this case, as the user 
%% info call will match the three-argument version of the function. If in the 
%% future the `request' is added as an argument to AO-Core's internal `info'
%% function, we will need to find a different approach.
info(_) -> #{ exports => [<<"info">>, <<"build">>] }.

%% @doc Utility function for determining if a request is from the `operator' of
%% the node.
is_operator(Request, NodeMsg) ->
    RequestSigners = hb_message:signers(Request, NodeMsg),
    Operator =
        hb_opts:get(
            operator,
            case hb_opts:get(priv_wallet, no_viable_wallet, NodeMsg) of
                no_viable_wallet -> unclaimed;
                Wallet -> ar_wallet:to_address(Wallet)
            end,
            NodeMsg
        ),
    EncOperator =
        case Operator of
            unclaimed -> unclaimed;
            NativeAddress -> hb_util:human_id(NativeAddress)
        end,
    EncOperator == unclaimed orelse lists:member(EncOperator, RequestSigners) orelse publickey_signer_matches_operator(RequestSigners, EncOperator).


publickey_signer_matches_operator(RequestSigners, EncOperator) ->
    lists:any(
        fun(Signer) ->
            case Signer of
                <<"publickey:", Rest/binary>> ->
                    try
                        Pub = base64:decode(Rest),
                        Derived = hb_util:human_id(crypto:hash(sha256, Pub)),
                        Derived == EncOperator
                    catch
                        _:_ -> false
                    end;
                _ ->
                    false
            end
        end,
        RequestSigners
    ).


extract_signature_keyid(RawRequest) ->
    SigInput = maps:get(<<"signature-input">>, RawRequest, undefined),
    case SigInput of
        Bin when is_binary(Bin) ->
            case binary:match(Bin, <<"keyid=\"">>) of
                {Pos, _Len} ->
                    Start = Pos + byte_size(<<"keyid=\"">>),
                    Rest = binary:part(Bin, Start, byte_size(Bin) - Start),
                    case binary:match(Rest, <<"\"">>) of
                        {EndPos, _} -> binary:part(Rest, 0, EndPos);
                        nomatch -> undefined
                    end;
                nomatch ->
                    undefined
            end;
        _ ->
            undefined
    end.

operator_address(NodeMsg) ->
    Default =
        case hb_opts:get(priv_wallet, no_viable_wallet, NodeMsg) of
            no_viable_wallet -> undefined;
            Wallet -> hb_util:id(ar_wallet:to_address(Wallet))
        end,
    Operator = hb_opts:get(operator, Default, NodeMsg),
    case Operator of
        undefined -> Default;
        unclaimed -> Default;
        Val when is_binary(Val) -> Val;
        Val -> hb_util:bin(Val)
    end.

keyid_to_operator_address(KeyId) when is_binary(KeyId) ->
    case KeyId of
        <<"arweave:", Rest/binary>> -> Rest;
        <<"publickey:", Rest/binary>> ->
            try
                Pub = base64:decode(Rest),
                hb_util:human_id(crypto:hash(sha256, Pub))
            catch
                _:_ -> undefined
            end;
        _ ->
            undefined
    end;
keyid_to_operator_address(_) -> undefined.

is_drewfi_operator(ReqMsg, RawRequest, NodeMsg) ->
    OpAddr = operator_address(NodeMsg),
    Commitments = maps:get(<<"commitments">>, ReqMsg, maps:get(<<"commitments">>, RawRequest, #{})),
    HasCommitments = is_map(Commitments) andalso map_size(Commitments) > 0,
    CommitterMatch =
        case {OpAddr, HasCommitments} of
            {undefined, _} -> false;
            {_, false} -> false;
            {_, true} ->
                lists:any(
                    fun({_Id, C}) ->
                        case C of
                            #{ <<"committer">> := Comm } when is_binary(Comm) -> Comm == OpAddr;
                            _ -> false
                        end
                    end,
                    maps:to_list(Commitments)
                )
        end,
    case CommitterMatch of
        true -> true;
        false ->
            KeyId = extract_signature_keyid(RawRequest),
            Derived = keyid_to_operator_address(KeyId),
            Derived =/= undefined andalso OpAddr =/= undefined andalso Derived == OpAddr
    end.

%% @doc Emits the version number and commit hash of the HyperBEAM node source,
%% if available.
%% 
%% We include the short hash separately, as the length of this hash may change in
%% the future, depending on the git version/config used to build the node.
%% Subsequently, rather than embedding the `git-short-hash-length', for the
%% avoidance of doubt, we include the short hash separately, as well as its long
%% hash.
build(_, _, _NodeMsg) ->
    {ok,
        #{
            <<"node">> => <<"HyperBEAM">>,
            <<"version">> => ?HYPERBEAM_VERSION,
            <<"source">> => ?HB_BUILD_SOURCE,
            <<"source-short">> => ?HB_BUILD_SOURCE_SHORT,
            <<"build-time">> => ?HB_BUILD_TIME
        }
    }.

%% @doc Normalize and route messages downstream based on their path. Messages
%% with a `Meta' key are routed to the `handle_meta/2' function, while all
%% other messages are routed to the `handle_resolve/2' function.
handle(NodeMsg, RawRequest) ->
    ?event({singleton_tabm_request, RawRequest}),
    NormRequest = hb_singleton:from(RawRequest, NodeMsg),
    ?event(
        http,
        {request,
            hb_cache:ensure_all_loaded(
                hb_ao:normalize_keys(NormRequest, NodeMsg),
                NodeMsg
            )
        }
    ),
    case hb_opts:get(initialized, false, NodeMsg) of
        false ->
            Res =
                embed_status(
                    hb_ao:force_message(
                        handle_initialize(NormRequest, NodeMsg),
                        NodeMsg
                    ),
                    NodeMsg
                ),
            Res;
        _ ->
            Path = try maps:get(<<"path">>, RawRequest) catch _:_ -> undefined end,
            case Path of
                <<"/~meta@1.0/drewfi/", _/binary>> ->
                    handle_drewfi_compute(RawRequest, NormRequest, NodeMsg);
                _ ->
                    handle_resolve(RawRequest, NormRequest, NodeMsg)
            end
    end.


handle_drewfi_compute(RawRequest, NormRequest, NodeMsg) ->
    Method = try maps:get(<<"method">>, RawRequest) catch _:_ -> <<"GET">> end,
    Path = try maps:get(<<"path">>, RawRequest) catch _:_ -> <<>> end,
    {RealPath, RawQS} =
        case binary:split(Path, <<"?">>) of
            [P, Q] -> {P, Q};
            [P] -> {P, <<>>}
        end,
    case {Method, RealPath} of
        {<<"GET">>, <<"/~meta@1.0/drewfi/cache">>} ->
            Params = uri_string:dissect_query(RawQS),
            PidOpt = lists:keyfind(<<"pid">>, 1, Params),
            SlotOpt = lists:keyfind(<<"slot">>, 1, Params),
            KeyOpt = lists:keyfind(<<"key">>, 1, Params),
            case {PidOpt, SlotOpt, KeyOpt} of
                {{_, Pid}, {_, SlotBin}, {_, KeyBin}} ->
                    Slot = try binary_to_integer(SlotBin) catch _:_ -> 0 end,
                    % Read the cached computed result for this pid/slot and return
                    % the requested cache key without triggering scheduler/compute.
                    case dev_process_cache:read(Pid, Slot, NodeMsg) of
                        {ok, Msg} ->
                            KeyPath =
                                case binary:match(KeyBin, <<"/">>) of
                                    nomatch -> <<"cache/", KeyBin/binary>>;
                                    _ -> KeyBin
                                end,
                            Value = hb_ao:get(KeyPath, Msg, not_found, NodeMsg),
                            embed_status(
                                {ok,
                                    #{
                                        <<"status">> => 200,
                                        <<"pid">> => Pid,
                                        <<"slot">> => Slot,
                                        <<"key">> => KeyBin,
                                        <<"value">> => Value
                                    }},
                                NodeMsg
                            );
                        _ ->
                            embed_status(
                                {not_found,
                                    #{
                                        <<"status">> => 404,
                                        <<"error">> => <<"cache_not_found">>,
                                        <<"pid">> => Pid,
                                        <<"slot">> => Slot,
                                        <<"key">> => KeyBin
                                    }},
                                NodeMsg
                            )
                    end;
                _ ->
                    embed_status(
                        {error,
                            #{
                                <<"status">> => 400,
                                <<"error">> => <<"missing_pid_slot_or_key">>
                            }},
                        NodeMsg
                    )
            end;
        {<<"POST">>, <<"/~meta@1.0/drewfi/compute">>} ->
            Params = uri_string:dissect_query(RawQS),
            PidOpt = lists:keyfind(<<"pid">>, 1, Params),
            SlotOpt = lists:keyfind(<<"slot">>, 1, Params),
            case {PidOpt, SlotOpt} of
                {{_, Pid}, {_, SlotBin}} ->
                    Slot = try binary_to_integer(SlotBin) catch _:_ -> 0 end,                    ReqMsg =
                        case NormRequest of
                            [_Base, Req | _] -> Req;
                            _ -> RawRequest
                        end,
                    Verified = hb_message:verify(ReqMsg, all, NodeMsg),
                    KeyId = extract_signature_keyid(RawRequest),
                    DerivedAddr = keyid_to_operator_address(KeyId),
                    OperatorAddr = operator_address(NodeMsg),
                    Authorized = Verified andalso is_drewfi_operator(ReqMsg, RawRequest, NodeMsg),
                    ?event(drewfi_crank, {req, {pid, Pid}, {slot, Slot}, {verified, Verified}, {keyid, KeyId}, {keyid_addr, DerivedAddr}, {operator, OperatorAddr}, {authorized, Authorized}}),
                    case Authorized of
                        false ->
                            embed_status(
                                {forbidden,
                                    #{
                                        <<"authorized">> => false,
                                        <<"verified">> => Verified,
                                        <<"keyid">> => KeyId,
                                        <<"keyid_addr">> => DerivedAddr,
                                        <<"operator">> => OperatorAddr,                                        <<"has_commitments_req">> => maps:is_key(<<"commitments">>, ReqMsg),
                                        <<"has_commitments_raw">> => maps:is_key(<<"commitments">>, RawRequest),
                                        <<"has_siginfo_raw">> => (maps:is_key(<<"signature">>, RawRequest) orelse maps:is_key(<<"signature-input">>, RawRequest)),
                                        <<"codec_device_raw">> => maps:get(<<"codec-device">>, RawRequest, undefined),
                                        <<"pid">> => Pid,
                                        <<"slot">> => Slot,
                                        <<"message">> => <<"unauthorized">>
                                    }},
                                NodeMsg
                            );
                        true ->
                            case hb_cache:read(Pid, NodeMsg) of
                                {ok, ProcessMsg} ->
                                    StartMs = erlang:monotonic_time(millisecond),
                                    StartLine = io_lib:format("~p ~p~n", [StartMs, {pid, Pid, slot, Slot, phase, start_sync}]),
                                    _ = file:write_file("/tmp/drewfi_compute.log", StartLine, [append]),
                                    ComputeRes = (catch dev_process:compute(ProcessMsg, #{ <<"slot">> => Slot }, NodeMsg)),
                                    EndMs = erlang:monotonic_time(millisecond),
                                    Duration = EndMs - StartMs,
                                    LogLine = io_lib:format("~p ~p~n", [StartMs, {pid, Pid, slot, Slot, ms, Duration, res, ComputeRes}]),
                                    _ = file:write_file("/tmp/drewfi_compute.log", LogLine, [append]),
                                    
                                    case ComputeRes of
                                        {ok, ResMap} when is_map(ResMap) ->
                                            embed_status({ok, ResMap}, NodeMsg);
                                        {error, Err} ->
                                            embed_status({error, Err}, NodeMsg);
                                        {'EXIT', Reason} ->
                                            embed_status({error, #{ <<"status">> => 500, <<"error">> => <<"compute_crash">>, <<"reason">> => hb_util:bin(io_lib:format("~p", [Reason])) }}, NodeMsg);
                                        Other ->
                                            embed_status({ok, #{ <<"status">> => 200, <<"result">> => hb_util:bin(io_lib:format("~p", [Other])) }}, NodeMsg)
                                    end;
                                _ ->
                                    embed_status(
                                        {not_found, #{ <<"error">> => <<"process_not_found">>, <<"pid">> => Pid }},
                                        NodeMsg
                                    )
                            end
                    end;
                _ ->
                    embed_status(
                        {error, #{ <<"status">> => 400, <<"error">> => <<"missing_pid_or_slot">> }},
                        NodeMsg
                    )
            end;
        {_, <<"/~meta@1.0/drewfi/compute">>} ->
            embed_status(
                {error, #{ <<"status">> => 405, <<"error">> => <<"method_not_allowed">>, <<"method">> => Method }},
                NodeMsg
            );
        _ ->
            embed_status(
                {not_found, #{ <<"status">> => 404, <<"error">> => <<"not_found">> }},
                NodeMsg
            )
    end.

handle_initialize([Base = #{ <<"device">> := Dev}, Req = #{ <<"path">> := Path }|_], NodeMsg) ->
    ?event({got, {device, Dev}, {path, Path}}),
    case {Dev, Path} of
        {<<"meta@1.0">>, <<"info">>} -> info(Base, Req, NodeMsg);
        _ -> {error, <<"Node must be initialized before use.">>}
    end;
handle_initialize([{as, <<"meta@1.0">>, _}|Rest], NodeMsg) ->
    handle_initialize([#{ <<"device">> => <<"meta@1.0">>}|Rest], NodeMsg);
handle_initialize([_|Rest], NodeMsg) ->
    handle_initialize(Rest, NodeMsg);
handle_initialize([], _NodeMsg) ->
    {error, <<"Node must be initialized before use.">>}.

%% @doc Get/set the node message. If the request is a `POST', we check that the
%% request is signed by the owner of the node. If not, we return the node message
%% as-is, aside all keys that are private (according to `hb_private').
info(_, Request, NodeMsg) ->
    case hb_ao:get(<<"method">>, Request, NodeMsg) of
        <<"POST">> ->
            case hb_ao:get(<<"initialized">>, NodeMsg, not_found, NodeMsg) of
                permanent ->
                    embed_status(
                        {error,
                            <<"The node message of this machine is already "
                                "permanent. It cannot be changed.">>
                        },
                        NodeMsg
                    );
                _ ->
                    update_node_message(Request, NodeMsg)
            end;
        _ ->
            ?event({get_config_req, Request, NodeMsg}),
            DynamicKeys = add_dynamic_keys(NodeMsg),	
            embed_status({ok, filter_node_msg(DynamicKeys, NodeMsg)}, NodeMsg)
    end.

%% @doc Remove items from the node message that are not encodable into a
%% message.
filter_node_msg(Msg, NodeMsg) when is_map(Msg) ->
    hb_maps:map(fun(_, Value) -> filter_node_msg(Value, NodeMsg) end, hb_private:reset(Msg), NodeMsg);
filter_node_msg(Msg, NodeMsg) when is_list(Msg) ->
    lists:map(fun(Item) -> filter_node_msg(Item, NodeMsg) end, Msg);
filter_node_msg(Tuple, _NodeMsg) when is_tuple(Tuple) ->
    <<"Unencodable value.">>;
filter_node_msg(Other, _NodeMsg) ->
    Other.

%% @doc Add dynamic keys to the node message.
add_dynamic_keys(NodeMsg) ->
    UpdatedNodeMsg = 
        case hb_opts:get(priv_wallet, no_viable_wallet, NodeMsg) of
            no_viable_wallet ->
                NodeMsg;
            Wallet ->
                %% Create a new map with address and merge it (overwriting existing)
                Address = hb_util:id(ar_wallet:to_address(Wallet)),
                NodeMsg#{ address => Address, <<"address">> => Address }
        end,
    add_identity_addresses(UpdatedNodeMsg).

add_identity_addresses(NodeMsg) ->
    Identities = hb_opts:get(identities, #{}, NodeMsg),
    NewIdentities = maps:map(fun(_, Identity) ->
        Identity#{
            <<"address">> => hb_util:human_id(
                hb_opts:get(priv_wallet, hb:wallet(), Identity)
            )
        }
    end, Identities),
    NodeMsg#{ <<"identities">> => NewIdentities }.

%% @doc Validate that the request is signed by the operator of the node, then
%% allow them to update the node message.
update_node_message(Request, NodeMsg) ->
    case is(admin, Request, NodeMsg) of
        false ->
            ?event({set_node_message_fail, Request}),
            embed_status({error, <<"Unauthorized">>}, NodeMsg);
        true ->
            case adopt_node_message(Request, NodeMsg) of
                {ok, NewNodeMsg} ->
                    NewH = hb_opts:get(node_history, [], NewNodeMsg),
                    embed_status(
                        {ok,
                            #{
                                <<"body">> =>
                                    iolist_to_binary(
                                        io_lib:format(
                                            "Node message updated. History: ~p"
                                                "updates.",
                                            [length(NewH)]
                                        )
                                    ),
                                <<"history-length">> => length(NewH)
                            }
                        },
                        NodeMsg
                    );
                {error, Reason} ->
                    ?event({set_node_message_fail, Request, Reason}),
                    embed_status({error, Reason}, NodeMsg)
            end
    end.

%% @doc Attempt to adopt changes to a node message.
adopt_node_message(Request, NodeMsg) ->
    ?event({set_node_message_success, Request}),
    % Ensure that the node history is updated and the http_server ID is
    % not overridden.
    case hb_opts:get(initialized, permanent, NodeMsg) of
        permanent ->
            {error, <<"Node message is already permanent.">>};
        _ ->
            hb_http_server:set_opts(Request, NodeMsg)
    end.

%% @doc Handle an AO-Core request, which is a list of messages. We apply
%% the node's pre-processor to the request first, and then resolve the request
%% using the node's AO-Core implementation if its response was `ok'.
%% After execution, we run the node's `response' hook on the result of
%% the request before returning the result it grants back to the user.
handle_resolve(Req, Msgs, NodeMsg) ->
    % Apply the pre-processor to the request.
    ?event(http_request,
        {resolve_hook,
            {raw_request, Req},
            {parsed_request_sequence, Msgs}
        }
    ),
    LoadedMsgs = hb_cache:ensure_all_loaded(Msgs, NodeMsg),
    case resolve_hook(<<"request">>, Req, LoadedMsgs, NodeMsg) of
        {ok, PreProcessedMsg} ->
            ?event(http_request, {request_after_preprocessing, PreProcessedMsg}),
            AfterPreprocOpts = hb_http_server:get_opts(NodeMsg),
            % Resolve the request message.
            HTTPOpts = hb_maps:merge(
                AfterPreprocOpts,
                hb_opts:get(http_extra_opts, #{}, NodeMsg),
				NodeMsg
            ),
            Res =
                hb_ao:resolve_many(
                    PreProcessedMsg,
                    HTTPOpts#{ force_message => true }
                ),
            {ok, StatusEmbeddedRes} = embed_status(Res, NodeMsg),
            AfterResolveOpts = hb_http_server:get_opts(NodeMsg),
            % Apply the post-processor to the result.
            Output = maybe_sign(
                embed_status(
                    resolve_hook(
                        <<"response">>,
                        Req,
                        StatusEmbeddedRes,
                        AfterResolveOpts
                    ),
                    NodeMsg
                ),
                NodeMsg
            ),
            ?event(http_request,
                {http_request,
                    {request, Req},
                    {result, Output}
                }
            ),
            Output;
        Res -> embed_status(hb_ao:force_message(Res, NodeMsg), NodeMsg)
    end.

%% @doc Execute a hook from the node message upon the user's request. The
%% invocation of the hook provides a request of the following form:
%% <pre>
%%      /path => request | response
%%      /request => the original request singleton
%%      /body => parsed sequence of messages to process | the execution result
%% </pre>
resolve_hook(HookName, InitiatingRequest, Body, NodeMsg) ->
    HookReq =
        #{
            <<"request">> => InitiatingRequest,
            <<"body">> => Body
        },
    ?event(hook, {resolve_hook, HookName, HookReq}),
    case dev_hook:on(HookName, HookReq, NodeMsg) of
        {ok, #{ <<"body">> := ResponseBody }} ->
            ?event(hook,
                {resolve_hook_success,
                    {name, HookName},
                    {response_body, ResponseBody}
                }
            ),
            {ok, ResponseBody};
        {error, _} = Error ->
            ?event(hook,
                {resolve_hook_error,
                    {name, HookName},
                    {error, Error}
                }
            ),
            Error;
        Other ->
            {error, Other}
    end.

%% @doc Wrap the result of a device call in a status.
embed_status({ErlStatus, Res}, NodeMsg) when is_map(Res) ->
    case lists:member(<<"status">>, hb_message:committed(Res, all, NodeMsg)) of
        false ->
            HTTPCode = status_code({ErlStatus, Res}, NodeMsg),
            {ok, Res#{ <<"status">> => HTTPCode }};
        true ->
            {ok, Res}
    end;
embed_status({ErlStatus, Res}, NodeMsg) ->
    HTTPCode = status_code({ErlStatus, Res}, NodeMsg),
    {ok, #{ <<"status">> => HTTPCode, <<"body">> => Res }}.

%% @doc Calculate the appropriate HTTP status code for an AO-Core result.
%% The order of precedence is:
%% 1. The status code from the message.
%% 2. The HTTP representation of the status code.
%% 3. The default status code.
status_code({ErlStatus, Msg}, NodeMsg) ->
    case message_to_status(Msg, NodeMsg) of
        default -> status_code(ErlStatus, NodeMsg);
        RawStatus -> RawStatus
    end;
status_code(ok, _NodeMsg) -> 200;
status_code(error, _NodeMsg) -> 400;
status_code(created, _NodeMsg) -> 201;
status_code(not_found, _NodeMsg) -> 404;
status_code(failure, _NodeMsg) -> 500;
status_code(unavailable, _NodeMsg) -> 503;
status_code(unauthorized, _NodeMsg) -> 401;
status_code(forbidden, _NodeMsg) -> 403;
status_code(_, _NodeMsg) -> 200.

%% @doc Get the HTTP status code from a transaction (if it exists).
message_to_status(#{ <<"body">> := Status }, NodeMsg) when is_atom(Status) ->
    status_code(Status, NodeMsg);
message_to_status(Item, NodeMsg) when is_map(Item) ->
    % Note: We use `dev_message' directly here, such that we do not cause 
    % additional AO-Core calls for every request. This is particularly important
    % if a remote server is being used for all AO-Core requests by a node.
    case dev_message:get(<<"status">>, Item, NodeMsg) of
        {ok, RawStatus} when is_integer(RawStatus) -> RawStatus;
        {ok, RawStatus} when is_atom(RawStatus) ->
            status_code(RawStatus, NodeMsg);
        {ok, RawStatus} ->
            % If we can convert the status to an integer, do so.
            try binary_to_integer(RawStatus)
            catch
                error:badarg ->
                    % We can't convert the status to an integer, but we may be
                    % able to convert it to an existing atom status code.
                    try
                        status_code(
                            binary_to_existing_atom(RawStatus, latin1),
                            NodeMsg
                        )
                    catch
                        error:badarg ->
                            % We can't convert the status to an integer or atom,
                            % so we return the default status code.
                            default
                    end
            end;
        _ -> default
    end;
message_to_status(Item, NodeMsg) when is_atom(Item) ->
    status_code(Item, NodeMsg);
message_to_status(_Item, _NodeMsg) ->
    default.

%% @doc Sign the result of a device call if the node is configured to do so.
maybe_sign({Status, Res}, NodeMsg) ->
    {Status, maybe_sign(Res, NodeMsg)};
maybe_sign(Res, NodeMsg) ->
    ?event({maybe_sign, Res}),
    case hb_opts:get(force_signed, false, NodeMsg) of
        true ->
            case hb_message:signers(Res, NodeMsg) of
                [] -> hb_message:commit(Res, NodeMsg);
                _ -> Res
            end;
        false -> Res
    end.

%% @doc Check if the request in question is signed by a given `role' on the node.
%% The `role' can be one of `operator' or `initiator'.
is(Request, NodeMsg) ->
    is(operator, Request, NodeMsg).
is(admin, Request, NodeMsg) ->
    % Does the caller have the right to change the node message?
    RequestSigners = hb_message:signers(Request, NodeMsg),
    ValidOperator =
        hb_util:bin(
            hb_opts:get(
                operator,
                case hb_opts:get(priv_wallet, no_viable_wallet, NodeMsg) of
                    no_viable_wallet -> unclaimed;
                    Wallet -> ar_wallet:to_address(Wallet)
                end,
                NodeMsg
            )
        ),
    EncOperator =
        case ValidOperator of
            <<"unclaimed">> -> unclaimed;
            NativeAddress -> hb_util:human_id(NativeAddress)
        end,
    ?event({is,
        {operator,
            {valid_operator, ValidOperator},
            {encoded_operator, EncOperator},
            {request_signers, RequestSigners}
        }
    }),
    EncOperator == unclaimed orelse lists:member(EncOperator, RequestSigners);
is(operator, Req, NodeMsg) ->
    % Is the caller explicitly set to be the operator?
    % Get the operator from the node message
    Operator = hb_opts:get(operator, unclaimed, NodeMsg),
    % Get the request signers
    RequestSigners = hb_message:signers(Req, NodeMsg),
    % Ensure the operator is present in the request
    lists:member(Operator, RequestSigners);
is(initiator, Request, NodeMsg) ->
    % Is the caller the first identity that configured the node message?
    NodeHistory = hb_opts:get(node_history, [], NodeMsg),
    % Check if node_history exists and is not empty
    case NodeHistory of
        [] ->
            ?event(green_zone, {init, node_history, empty}),
            false;
        [InitializationRequest | _] ->
            % Extract signature from first entry
            InitializationRequestSigners = hb_message:signers(InitializationRequest, NodeMsg),
            % Get request signers
            RequestSigners = hb_message:signers(Request, NodeMsg),
            % Ensure all signers of the initalization request are present in the
            % request.
            AllSignersPresent =
                lists:all(
                    fun(Signer) -> lists:member(Signer, RequestSigners) end,
                    InitializationRequestSigners
                ),
            case AllSignersPresent of
                true ->
                    {ok, true};
                false ->
                    {error, #{
                        <<"status">> => 401,
                        <<"message">> => <<"Invalid request signature.">>
                    }}
            end
    end.

%%% Tests

%% @doc Test that we can get the node message.
config_test() ->
	StoreOpts = #{
		<<"store-module">> => hb_store_fs,
		<<"name">> => <<"cache-TEST">>
	},
    Node = hb_http_server:start_node(Opts = #{ test_config_item => <<"test">>, store => StoreOpts }),
    {ok, Res} = hb_http:get(Node, <<"/~meta@1.0/info">>, Opts),
    ?assertEqual(<<"test">>, hb_ao:get(<<"test_config_item">>, Res, Opts)).

%% @doc Test that we can't get the node message if the requested key is private.
priv_inaccessible_test() ->
    Node = hb_http_server:start_node(
        #{
            test_config_item => <<"test">>,
            priv_key => <<"BAD">>
        }
    ),
    {ok, Res} = hb_http:get(Node, <<"/~meta@1.0/info">>, #{}),
    ?event({res, Res}),
    ?assertEqual(<<"test">>, hb_ao:get(<<"test_config_item">>, Res, #{})),
    ?assertEqual(not_found, hb_ao:get(<<"priv_key">>, Res, #{})).

%% @doc Test that we can't set the node message if the request is not signed by
%% the owner of the node.
unauthorized_set_node_msg_fails_test() ->
	StoreOpts = #{
		<<"store-module">> => hb_store_fs,
		<<"name">> => <<"cache-TEST">>
	},
    Node = hb_http_server:start_node(Opts = #{ store => StoreOpts, priv_wallet => ar_wallet:new() }),
    {error, _} =
        hb_http:post(
            Node,
            hb_message:commit(
                #{
                    <<"path">> => <<"/~meta@1.0/info">>,
                    <<"evil_config_item">> => <<"BAD">>
                },
                Opts#{ priv_wallet => ar_wallet:new() }
            ),
            #{}
        ),
    {ok, Res} = hb_http:get(Node, <<"/~meta@1.0/info">>, Opts),
    ?assertEqual(not_found, hb_ao:get(<<"evil_config_item">>, Res, Opts)),
    ?assertEqual(0, length(hb_ao:get(<<"node_history">>, Res, [], Opts))).

%% @doc Test that we can set the node message if the request is signed by the
%% owner of the node.
authorized_set_node_msg_succeeds_test() ->
	StoreOpts = #{
		<<"store-module">> => hb_store_fs,
		<<"name">> => <<"cache-TEST">>
	},
    Owner = ar_wallet:new(),
    Node = hb_http_server:start_node(
        Opts = #{
            operator => hb_util:human_id(ar_wallet:to_address(Owner)),
            test_config_item => <<"test">>,
			store => StoreOpts
        }
    ),
    {ok, SetRes} =
        hb_http:post(
            Node,
            hb_message:commit(
                #{
                    <<"path">> => <<"/~meta@1.0/info">>,
                    <<"test_config_item">> => <<"test2">>
                },
                Opts#{ priv_wallet => Owner }
            ),
            Opts
        ),
    ?event({res, SetRes}),
    {ok, Res} = hb_http:get(Node, <<"/~meta@1.0/info">>, Opts),
    ?event({res, Res}),
    ?assertEqual(<<"test2">>, hb_ao:get(<<"test_config_item">>, Res, Opts)),
    ?assertEqual(1, length(hb_ao:get(<<"node_history">>, Res, [], Opts))).

%% @doc Test that an uninitialized node will not run computation.
uninitialized_node_test() ->
    Node = hb_http_server:start_node(#{ initialized => false }),
    {error, Res} = hb_http:get(Node, <<"/key1?1.key1=value1">>, #{}),
    ?event({res, Res}),
    ?assertEqual(<<"Node must be initialized before use.">>, Res).

%% @doc Test that a permanent node message cannot be changed.
permanent_node_message_test() ->
	StoreOpts = #{
		<<"store-module">> => hb_store_fs,
		<<"name">> => <<"cache-TEST">>
	},
    Owner = ar_wallet:new(),
    Node = hb_http_server:start_node(
        Opts =#{
            operator => <<"unclaimed">>,
            initialized => false,
            test_config_item => <<"test">>,
			store => StoreOpts
        }
    ),
    {ok, SetRes1} =
        hb_http:post(
            Node,
            hb_message:commit(
                #{
                    <<"path">> => <<"/~meta@1.0/info">>,
                    <<"test_config_item">> => <<"test2">>,
                    initialized => <<"permanent">>
                },
                Opts#{ priv_wallet => Owner }
            ),
            Opts
        ),
    ?event({set_res, SetRes1}),
    {ok, Res} = hb_http:get(Node, #{ <<"path">> => <<"/~meta@1.0/info">> }, Opts),
    ?event({get_res, Res}),
    ?assertEqual(<<"test2">>, hb_ao:get(<<"test_config_item">>, Res, Opts)),
    {error, SetRes2} =
        hb_http:post(
            Node,
            hb_message:commit(
                #{
                    <<"path">> => <<"/~meta@1.0/info">>,
                    <<"test_config_item">> => <<"bad_value">>
                },
                Opts#{ priv_wallet => Owner }
            ),
            Opts
        ),
    ?event({set_res, SetRes2}),
    {ok, Res2} = hb_http:get(Node, #{ <<"path">> => <<"/~meta@1.0/info">> }, Opts),
    ?event({get_res, Res2}),
    ?assertEqual(<<"test2">>, hb_ao:get(<<"test_config_item">>, Res2, Opts)),
    ?assertEqual(1, length(hb_ao:get(<<"node_history">>, Res2, [], Opts))).

%% @doc Test that we can claim the node correctly and set the node message after.
claim_node_test() ->
	StoreOpts = #{
		<<"store-module">> => hb_store_fs,
		<<"name">> => <<"cache-TEST">>
	},
    Owner = ar_wallet:new(),
    Address = ar_wallet:to_address(Owner),
    Node = hb_http_server:start_node(
        Opts = #{
            operator => unclaimed,
            test_config_item => <<"test">>,
			store => StoreOpts
        }
    ),
    {ok, SetRes} =
        hb_http:post(
            Node,
            hb_message:commit(
                #{
                    <<"path">> => <<"/~meta@1.0/info">>,
                    <<"operator">> => hb_util:human_id(Address)
                },
                Opts#{ priv_wallet => Owner}
            ),
            Opts
        ),
    ?event({res, SetRes}),
    {ok, Res} = hb_http:get(Node, <<"/~meta@1.0/info">>, Opts),
    ?event({res, Res}),
    ?assertEqual(hb_util:human_id(Address), hb_ao:get(<<"operator">>, Res, Opts)),
    {ok, SetRes2} =
        hb_http:post(
            Node,
            hb_message:commit(
                #{
                    <<"path">> => <<"/~meta@1.0/info">>,
                    <<"test_config_item">> => <<"test2">>
                },
                Opts#{ priv_wallet => Owner }
            ),
            Opts
        ),
    ?event({res, SetRes2}),
    {ok, Res2} = hb_http:get(Node, <<"/~meta@1.0/info">>, Opts),
    ?event({res, Res2}),
    ?assertEqual(<<"test2">>, hb_ao:get(<<"test_config_item">>, Res2, Opts)),
    ?assertEqual(2, length(hb_ao:get(<<"node_history">>, Res2, [], Opts))).

%% Test that we can use a hook upon a request.
request_response_hooks_test() ->
    Parent = self(),
    Node = hb_http_server:start_node(
        #{
            on =>
                #{
                    <<"request">> =>
                        #{
                            <<"device">> => #{
                                <<"request">> =>
                                    fun(_, #{ <<"body">> := Msgs }, _) ->
                                        Parent ! {hook, request},
                                        {ok, #{ <<"body">> => Msgs} }
                                    end
                            }
                        },
                    <<"response">> =>
                        #{
                            <<"device">> => #{
                                <<"response">> =>
                                    fun(_, #{ <<"body">> := Msgs }, _) ->
                                        Parent ! {hook, response},
                                        {ok, #{ <<"body">> => Msgs} }
                                    end
                            }
                        }
                },
            http_extra_opts => #{
                <<"cache-control">> => [<<"no-store">>, <<"no-cache">>]
            }
        }),
    hb_http:get(Node, <<"/~meta@1.0/info">>, #{}),
    % Receive both of the responses from the hooks, if possible.
    Res =
        receive
            {hook, request} ->
                receive {hook, response} -> true after 100 -> false end
            after 100 ->
                false
        end,
    ?assert(Res).

%% @doc Test that we can halt a request if the hook returns an error.
halt_request_test() ->
    Node = hb_http_server:start_node(
        #{
            on =>
                #{
                    <<"request">> =>
                        #{
                            <<"device">> => #{
                                <<"request">> =>
                                    fun(_, _, _) ->
                                        {error, <<"Bad">>}
                                    end
                            }
                        }
                }
        }),
    {error, Res} = hb_http:get(Node, <<"/~meta@1.0/info">>, #{}),
    ?assertEqual(<<"Bad">>, Res).

%% @doc Test that a hook can modify a request.
modify_request_test() ->
    Node = hb_http_server:start_node(
        #{
            on =>
                #{
                    <<"request">> =>
                        #{
                            <<"device">> => #{
                                <<"request">> =>
                                    fun(_, #{ <<"body">> := [M|Ms] }, _) ->
                                        {
                                            ok,
                                            #{
                                                <<"body">> =>
                                                    [
                                                        M#{
                                                            <<"added">> =>
                                                                <<"value">>
                                                        }
                                                    |
                                                        Ms
                                                    ]
                                            }
                                        }
                                    end
                            }
                        }
                }
        }),
    {ok, Res} = hb_http:get(Node, <<"/added">>, #{}),
    ?assertEqual(<<"value">>, Res).

%% @doc Test that version information is available and returned correctly.
buildinfo_test() ->
    Node = hb_http_server:start_node(#{}),
    ?assertEqual(
        {ok, <<"HyperBEAM">>},
        hb_http:get(Node, <<"/~meta@1.0/build/node">>, #{})
    ),
    ?assertEqual(
        {ok, ?HYPERBEAM_VERSION},
        hb_http:get(Node, <<"/~meta@1.0/build/version">>, #{})
    ),
    ?assertEqual(
        {ok, ?HB_BUILD_SOURCE},
        hb_http:get(Node, <<"/~meta@1.0/build/source">>, #{})
    ),
    ?assertEqual(
        {ok, ?HB_BUILD_SOURCE_SHORT},
        hb_http:get(Node, <<"/~meta@1.0/build/source-short">>, #{})
    ),
    ?assertEqual(
        {ok, ?HB_BUILD_TIME},
        hb_http:get(Node, <<"/~meta@1.0/build/build-time">>, #{})
    ).

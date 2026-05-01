%%% @doc A library of common functions for building devices that interact with 
%%% the `~process@1.0` meta-device structure.
-module(dev_process_lib).
-include("include/hb.hrl").
-export([as_process/2, run_as/4, process_id/3, set_results/3, ensure_process_key/2]).

%% @doc Returns the process ID of the current process.
process_id(Base, Req, Opts) ->
    case hb_maps:get(<<"process">>, Base, not_found, Opts) of
        not_found ->
            process_id(ensure_process_key(Base, Opts), Req, Opts);
        Process ->
            CommitmentMode = hb_util:atom(maps:get(<<"commitments">>, Req, <<"signed">>)),
            Verified =
                hb_message:verify(Process, signers, Opts)
                    orelse hb_message:verify(Process, all, Opts),
            case Verified of
                false ->
                    % DrewFi: avoid turning verification failures into total liveness loss.
                    % Some operations (e.g. outbox delivery pushes) are still safe/necessary
                    % to attempt even when the process message cannot be fully verified due
                    % to lazy link resolution or partial cache availability.
                    ?event({process_not_verified, {process, Process}});
                true ->
                    ok
            end,
            case Verified of
                false ->
                    % Safety: when verification fails, do not attempt to derive a PID from
                    % potentially incomplete/incorrect commitment sets. Fall back to the
                    % default process/message id to avoid mis-routing schedules/pushes.
                    hb_message:id(Process, CommitmentMode, Opts);
                true ->
                    case process_pid_from_commitments(Process, Opts) of
                        not_found ->
                            DefaultId = hb_message:id(Process, CommitmentMode, Opts),
                            case pick_any_non_hmac_commitment_id(Process, Opts) of
                                not_found -> DefaultId;
                                Pid -> Pid
                            end;
                        Pid ->
                            Pid
                    end
            end
    end.

process_pid_from_commitments(Process, Opts) ->
    Commitments = hb_maps:get(<<"commitments">>, Process, #{}, Opts),
    case is_map(Commitments) of
        false -> not_found;
        true ->
            % Prefer a commitment that is clearly "signed" (has a committer),
            % and then narrow to ANS-104 when possible. This avoids accidentally
            % picking internal/unsigned IDs (e.g. constant:ao HMAC).
            CommitmentList = hb_maps:to_list(Commitments, Opts),
            case pick_ans104_commitment_id(CommitmentList, Opts) of
                not_found ->
                    case pick_any_committer_id(CommitmentList, Opts) of
                        not_found ->
                            case pick_any_publickey_keyid(CommitmentList, Opts) of
                                not_found ->
                                    pick_any_non_constant_keyid(CommitmentList, Opts);
                                Pid -> Pid
                            end;
                        Pid -> Pid
                    end;
                Pid ->
                    Pid
            end
    end.

pick_any_committer_id([], _Opts) ->
    not_found;
pick_any_committer_id([{Key, Val} | Rest], Opts) when is_map(Val) ->
    case hb_maps:get(<<"committer">>, Val, not_found, Opts) of
        not_found -> pick_any_committer_id(Rest, Opts);
        _Committer -> hb_util:human_id(Key)
    end;
pick_any_committer_id([_ | Rest], Opts) ->
    pick_any_committer_id(Rest, Opts).

pick_ans104_commitment_id([], _Opts) ->
    not_found;
pick_ans104_commitment_id([{Key, Val} | Rest], Opts) when is_map(Val) ->
    case hb_maps:get(<<"commitment-device">>, Val, not_found, Opts) of
        <<"ans104@1.0">> -> hb_util:human_id(Key);
        _ -> pick_ans104_commitment_id(Rest, Opts)
    end;
pick_ans104_commitment_id([_ | Rest], Opts) ->
    pick_ans104_commitment_id(Rest, Opts).

pick_any_publickey_keyid([], _Opts) ->
    not_found;
pick_any_publickey_keyid([{Key, Val} | Rest], Opts) when is_map(Val) ->
    case hb_maps:get(<<"keyid">>, Val, not_found, Opts) of
        <<"publickey:", _/binary>> -> hb_util:human_id(Key);
        _ -> pick_any_publickey_keyid(Rest, Opts)
    end;
pick_any_publickey_keyid([_ | Rest], Opts) ->
    pick_any_publickey_keyid(Rest, Opts).

pick_any_non_constant_keyid([], _Opts) ->
    not_found;
pick_any_non_constant_keyid([{Key, Val} | Rest], Opts) when is_map(Val) ->
    case hb_maps:get(<<"keyid">>, Val, not_found, Opts) of
        not_found -> pick_any_non_constant_keyid(Rest, Opts);
        <<"constant:ao">> -> pick_any_non_constant_keyid(Rest, Opts);
        _Other -> hb_util:human_id(Key)
    end;
pick_any_non_constant_keyid([_ | Rest], Opts) ->
    pick_any_non_constant_keyid(Rest, Opts).

pick_any_non_hmac_commitment_id(Process, Opts) when is_map(Process) ->
    Commitments = hb_maps:get(<<"commitments">>, Process, #{}, Opts),
    case is_map(Commitments) of
        false -> not_found;
        true ->
            CommitmentList = hb_maps:to_list(Commitments, Opts),
            HmacIds =
                [
                    hb_util:human_id(Key)
                ||
                    {Key, Val} <- CommitmentList,
                    is_map(Val),
                    hb_maps:get(<<"keyid">>, Val, not_found, Opts) =:= <<"constant:ao">>
                ],
            case HmacIds of
                [HmacId] ->
                    Keys =
                        lists:map(
                            fun({Key, _}) -> hb_util:human_id(Key) end,
                            CommitmentList
                        ),
                    case lists:delete(HmacId, Keys) of
                        [] -> not_found;
                        [Pid | _] -> Pid
                    end;
                _ ->
                    not_found
            end
    end;
pick_any_non_hmac_commitment_id(_, _) ->
    not_found.

%% @doc Run a message against Base, with the device being swapped out for
%% the device found at `Key'. After execution, the device is swapped back
%% to the original device if the device is the same as we left it.
run_as(Key, Base, Path, Opts) when not is_map(Path) ->
    run_as(Key, Base, #{ <<"path">> => Path }, Opts);
run_as(Key, Base, Req, Opts) ->
    % Store the original device so we can restore it after execution
    BaseDevice = hb_maps:get(<<"device">>, Base, not_found, Opts),
    ForceLuaInit = hb_opts:get(force_lua_init, false, Opts),
    UseLuaInit = (ForceLuaInit == true andalso Key == <<"execution">>),
    ?event({running_as, {key, {explicit, Key}}, {req, Req}}),
    % Prepare the message with the specialized device configuration.
    % This sets up the device context for the specific operation type.
    PreparedMsg =
        hb_util:deep_merge(
            ensure_process_key(Base, Opts),
            #{
                <<"device">> =>
                    DeviceSet =
                        case UseLuaInit of
                            true -> <<"lua@5.3a">>;
                            false ->
                                hb_maps:get(
                                    << Key/binary, "-device">>,
                                    Base,
                                    dev_process:default_device(Base, Key, Opts),
                                    Opts
                                )
                        end,
                % Configure input prefix for proper message routing within the device
                <<"input-prefix">> =>
                    case hb_maps:get(<<"input-prefix">>, Base, not_found, Opts) of
                        not_found -> <<"process">>;
                        Prefix -> Prefix
                    end,
                % Configure output prefixes for result organization
                <<"output-prefixes">> =>
                    hb_maps:get(
                        <<Key/binary, "-output-prefixes">>,
                        Base,
                        undefined, % Undefined in set will be ignored.
                        Opts
                    )
            },
            Opts
        ),
    ?event(debug_prefix,
        {input_prefix, hb_maps:get(<<"output-prefixes">>, PreparedMsg, not_found, Opts)
    }),
    % Execute the message through the specialized device.
    {Status, BaseResult} =
        hb_ao:resolve(PreparedMsg, Req, Opts),
    % Restore the original device context after execution.
    % This ensures the process maintains its identity after device delegation.
    case {Status, BaseResult} of
        {ok, #{ <<"device">> := DeviceSet }} ->
            {ok, hb_ao:set(BaseResult, #{ <<"device">> => BaseDevice }, Opts)};
        _ ->
            ?event({returning_base_result, BaseResult}),
            {Status, BaseResult}
    end.

%% @doc Change the message to for that has the device set as this module.
%% In situations where the key that is `run_as' returns a message with a 
%% transformed device, this is useful.
as_process(Base, Opts) ->
    {ok, Proc} = dev_message:set(Base, #{ <<"device">> => <<"process@1.0">> }, Opts),
    Proc.

%% @doc Set the results of the current process.
set_results(State, Results, Opts) ->
    {ok, hb_ao:set(State, #{ <<"results">> => Results }, Opts)}.


%% @doc Helper function to store a copy of the `process' key in the message.
ensure_process_key(Base, Opts) ->
    case hb_maps:get(<<"process">>, Base, not_found, Opts) of
        not_found ->
            % If the message has lost its signers, we need to re-read it from
            % the cache. This can happen if the message was 'cast' to a different
            % device, leading the signers to be unset.
            {ok, Committed} = hb_message:with_only_committed(Base, Opts),
            ?event(
                {process_key_before_set,
                    {base, Base},
                    {process_msg, Base},
                    {committed, Committed}
                }
            ),
            Res =
                hb_ao:set(
                    % Keep the original message shape intact (including derived
                    % keys like `device-stack`), and only add the nested `process`
                    % key. Stripping down to "uncommitted" can remove fields
                    % required by stack execution.
                    Base,
                    #{ <<"process">> => Committed },
                    Opts#{ hashpath => ignore }
                ),
            ?event(
                {set_process_key_res,
                    {base, Base},
                    {process_msg, Base},
                    {res, Res}
                }
            ),
            Res;
        _ -> Base
    end.

%% Copyright (c) 2024 Robert Virding
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% File    : luerl_init.erl
%% Author  : Robert Virding
%% Purpose : Luerl init module.

-module(luerl_init).

%%% The calls needed to start user/user_drv have changed from OTP
%%% 26. In the release after 26 the module user no longer exists and
%%% user_drv has a different interface. Note that this is sort of
%%% documented but these modules are not included in the standard
%%% Erlang documentation.

-export([start/0]).

-define(OK_STATUS, 0).
-define(ERROR_STATUS, 127).

%% Start Luerl running a script or the shell depending on arguments.

start() ->
    OTPRelease = erlang:system_info(otp_release),
    %% erlang:display(init:get_plain_arguments()),
    case collect_args(init:get_plain_arguments()) of
        {[],[]} ->                              %Run a shell
	    if OTPRelease >= "26" ->
		    %% The new way 26 and later.
		    user_drv:start(#{initial_shell => {luerl_shell,start,[]}});
	       true ->
		    %% The old way before 26.
		    user_drv:start(['tty_sl -c -e',{luerl_shell,start,[]}])
	    end;
        {Es,Chunk} ->
	    if OTPRelease >= "26" ->
		    %% The new way 26 and later)
		    user_drv:start(#{initial_shell => noshell});
	       true ->
		    %% The old way before 26.
		    user:start()
	    end,
	    erlang:display({Es,Chunk}),
	    run_evals_chunk(Es, Chunk)
    end.

collect_args([E,S|As]) when E == "-luerl_eval" ; E == "-eval" ; E == "-e" ->
    {Es,Script} = collect_args(As),
    {[S] ++ Es,Script};
collect_args([E]) when E == "-luerl_eval" ; E == "-eval" ; E == "-e" ->
    {[],[]};
collect_args(As) -> {[],As}.                    %Remaining become script

%% run_evals_chunk(Evals, Chunk) -> Pid.

run_evals_chunk(Es, Chunk) ->
    run_strings(Es),
    run_chunk(Chunk).

%% run_strings(Strings)

run_strings([]) -> ok;
run_strings(_) ->
    erlang:display("strings NYI"),
    halt(?ERROR_STATUS).

% run_chunk(FileName)

run_chunk([]) -> ok;
run_chunk(_) ->
    erlang:display("chunk NYI"),
    halt(?ERROR_STATUS).

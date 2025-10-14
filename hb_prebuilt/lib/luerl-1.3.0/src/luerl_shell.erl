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

%% File    : luerl_shell.erl
%% Author  : Robert Virding
%% Purpose : A basic LUA 5.3 shell for Luerl.

%% This is a simple shell which mirrors the Lua shell. Note there is
%% no implicit return to show values of expressions.

-module(luerl_shell).

-export([start/0,start/1,server/0,server/1]).

-export([collect_line/2]).

-include("luerl.hrl").

-record(shell, {state}).

start() -> start(default).

start(Env) ->
    spawn(fun () -> server(Env) end).

server() -> server(default).

server(default) ->
    State = luerl:init(),
    server(State);
server(State) ->
    Sh = #shell{state=State},
    server_loop(Sh).

server_loop(#shell{state=St0}=Shell) ->
    Input = get_input("> "),
    NewSt =
        case eval_input(Input, St0) of
            {ok,_Ret,St1} ->
                %% The return has alreay been printed.
                St1;
            {parse_error,Errors} ->
                list_errors(Errors),
                St0;
            {lua_error,Err,St1} ->
                Err0 = luerl_lib:format_error(Err),
                io:format("Error: ~ts\n", [Err0]),
		show_stack(St1),
                %% Must clear the stack.
                St1#luerl{stk=[]}
        end,
    server_loop(Shell#shell{state = NewSt}).

%% show_stack(State) -> ok.
%%  Show the current stack.

show_stack(St) ->
    %% io:format("Stack: ~p\n", [St#luerl.cs]),
    Stk = luerl:get_stacktrace(St),
    io:format("Stack:\n", []),
    lists:foreach(fun (F) -> io:format("    ~p\n", [F]) end, Stk).

%% get_input(Prompt) -> Input
%%  Collect input lines while they end with '\'.

get_input(Prompt) ->
    Line = get_line(Prompt),
    case lists:suffix("\\\n", Line) of
        true ->
            Len = length(Line),
            Input = lists:sublist(Line, Len - 2) ++ "\n" ++ get_input(">> "),
            Input;
        false ->
            Line
    end.

%% get_line(Prompt) -> Data | {error,Error} | eof.
%% get_line(IoDevice, Prompt) -> Data | {error,Error} | eof.
%%  Reads a line from the standard input (IoDevice), prompting it with
%%  Prompt. Doing it this way saves the input in history.

get_line(Prompt) ->
    get_line(standard_io, Prompt).

get_line(IoDevice, Prompt) ->
    io:request(IoDevice, {get_until,unicode,Prompt,luerl_shell,collect_line,[]}).

%% collect_line(OldStack, Data) -> {done,Result,Rest} | {more,NewStack}.

collect_line(Stack, Data) ->
    case io_lib:collect_line(start, Data, unicode, ignored) of
        {stop,Result,Rest} ->
            {done,lists:reverse(Stack, Result),Rest};
        MoreStack ->
            {more,MoreStack ++ Stack}
    end.

%% eval_input(Input, State) ->
%%     {ok,Ret,State} | {lua_error,Error,State} | {parse_error,Errors}.
%%  This is slightly tricky as both expressions and statements are
%%  allowed. The value of an expression should printed while the value
%%  of a statement is ignored. We first try an expression by wrapping
%%  print( ... ) around input, if that doesn't parse we try it as a
%%  statement.

eval_input(Input, St0) ->
    io:format("eval input ~p\n", [Input]),
    case eval_input_exprs(Input, St0) of
        {ok,_Ret,_St1} = Return ->
            %% io:format("eval return ~p\n", [_Ret]),
            Return;
        {lua_error,_Error,_St} = LuaError ->
            %% The expression was ok but generated an error.
            LuaError;
        _Error ->
            %% Other error which we ignore and pass the buck.
            eval_input_stats(Input, St0)
    end.

eval_input_exprs(Input, St0) ->
    PrintInput = "print( " ++ Input ++ ")",
    io:format("eval expr input ~p\n", [PrintInput]),
    case luerl_comp:string(PrintInput, [return]) of
        {ok,Chunk} ->
            load_eval_chunk(Chunk, St0);
        {error,Error,_} ->                      %Pass the buck
            %% io:format("eval expr error ~p\n", [Error]),
            {parse_error,Error}
    end.

eval_input_stats(Input, St0) ->
    io:format("eval stats input ~p\n", [Input]),
    case luerl_comp:string(Input, [return]) of
        {ok,Chunk} ->
            load_eval_chunk(Chunk, St0);
        {error,Error,_} ->                      %Return the parse error
            %% io:format("eval stats error ~p\n", [Error]),
            {parse_error,Error}
    end.

%% load_eval_chunk(Chunk, State) ->
%%     {ok,Return,Stated} | {lua_error,Error,State}.
%%   Load in a compiled chunk and call it.

load_eval_chunk(Chunk, St0) ->
    %% io:format("eval chunk ~p\n", [Chunk]),
    {Func,St1} = luerl_emul:load_chunk(Chunk, St0),
    try
        {Ret,St2} = luerl_emul:functioncall(Func, [], St1),
        {ok,Ret,St2}
    catch
        error:{lua_error,_E,_St} = LuaErr ->
            LuaErr
    end.

%% list_parse_errors(Errors) -> ok.
%%  List parse errors in the same way as the compiler does.

list_errors(Errors) ->
    Efun = fun ({Line,Mod,Error}) ->
                   Chars = Mod:format_error(Error),
                   io:format("~w: ~s\n", [Line,Chars]);
               ({Mod,Error}) ->
                   Chars = Mod:format_error(Error),
                   io:format("~s\n", [Chars])
           end,
    lists:foreach(Efun, Errors).

-module(prometheus_httpd).
-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.
?MODULEDOC("""
Exports Prometheus metrics via configurable endpoint.

### Existing httpd:
```
{modules, [
    ...
    prometheus_httpd
    ...
]},
```

### Built-in httpd instance:<br/>
```
prometheus_httpd:start()
```

### Telemetry metrics

- `telemetry_scrape_duration_seconds`
- `telemetry_scrape_size_bytes`
- `telemetry_scrape_encoded_size_bytes`

### Configuration

Can be configured via `prometheus_http` key of `prometheus` app env.

Default configuration:
```
{prometheus, [
    ...
    {prometheus_http, [{path, \"/metrics\"},
                       {format, auto},
                       {port, 8081}]},
    ...
]}
```
""").

-export([start/0]).

%% httpd mod callbacks
-export([do/1]).

-include_lib("inets/include/httpd.hrl").

-define(SERVER_NAME, "Prometheus.io metrics.").

-behaviour(application).
-export([start/2, stop/1]).
-behaviour(supervisor).
-export([init/1]).

%% ===================================================================
%% Public API
%% ===================================================================

?DOC("""
Starts inets httpd server with `promtheus_httpd` module enabled.

Also calls `prometheus_http_impl:setup/0`.
""").
-spec start() -> {ok, pid()} | {error, term()}.
start() ->
    inets:start(httpd, [
        {modules, [
            prometheus_httpd
        ]},
        {port, prometheus_http_config:port()},
        {server_name, ?SERVER_NAME},
        {document_root, code:priv_dir(prometheus_httpd)},
        {server_root, code:priv_dir(prometheus_httpd)}
    ]).

?DOC(false).
-spec do(term()) -> {break, [term()]} | {proceed, term()}.
do(Info) ->
    URI = Info#mod.request_uri,
    Headers = Info#mod.parsed_header,
    GetHeader = fun(Name, Default) ->
        proplists:get_value(Name, Headers, Default)
    end,

    %% TODO: check method, response only to GET
    case
        prometheus_http_impl:reply(#{
            path => URI,
            headers => GetHeader,
            registry => undefined,
            standalone => standalone_p(Info)
        })
    of
        {Code, RespHeaders0, Body} ->
            ContentLength = integer_to_list(iolist_size(Body)),
            RespHeaders =
                RespHeaders0 ++
                    [
                        {code, Code},
                        {content_length, ContentLength}
                    ],
            {break, [{response, {response, RespHeaders, [Body]}}]};
        false ->
            {proceed, Info#mod.data}
    end.

%% ===================================================================
%% Application & supervisor callbacks
%% ===================================================================

?DOC(false).
-spec start(application:start_type(), term()) ->
    {ok, pid()} | {ok, pid(), term()} | {error, term()}.
start(_, _) ->
    prometheus_http_impl:setup(),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

?DOC(false).
-spec stop(term()) -> term().
stop(_) -> ok.

?DOC(false).
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    {ok, {{one_for_one, 0, 1}, []}}.

%% ===================================================================
%% Private Parts
%% ===================================================================

standalone_p(#mod{config_db = ConfigDb}) ->
    case httpd_util:lookup(ConfigDb, server_name) of
        ?SERVER_NAME ->
            true;
        _ ->
            false
    end.

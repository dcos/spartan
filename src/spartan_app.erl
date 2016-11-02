-module(spartan_app).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(application).
-export([start/2, stop/1]).

%% Application
-export([
    wait_for_reqid/2,
    parse_ipv4_address/1,
    parse_ipv4_address_with_port/2
]).

-include("spartan.hrl").
-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

-define(TCP_LISTENER_NAME, spartan_tcp_listener).

-define(COMPILE_OPTIONS,
        [verbose,
         report_errors,
         report_warnings,
         no_error_module_mismatch,
         {source, undefined}]).


%%====================================================================
%% Application Behavior
%%====================================================================

start(_StartType, _StartArgs) ->
    maybe_load_json_config(), %% Maybe load the relevant DCOS configuration
    maybe_start_tcp_listener(),
    Ret = spartan_sup:start_link(),
    Ret.

stop(_State) ->
    ranch:stop_listener(?TCP_LISTENER_NAME),
    ok.

%%====================================================================
%% General API
%%====================================================================

%% @doc Wait for a response.
wait_for_reqid(ReqID, Timeout) ->
    receive
        {ReqID, ok} ->
            ok;
        {ReqID, ok, Val} ->
            {ok, Val}
    after Timeout ->
        {error, timeout}
    end.

%% @doc Parse an IPv4 Address
-spec parse_ipv4_address(binary()|list()) -> inet:ip4_address().
parse_ipv4_address(Value) when is_binary(Value) ->
    parse_ipv4_address(binary_to_list(Value));
parse_ipv4_address(Value) ->
    {ok, IP} = inet:parse_ipv4_address(Value),
    IP.

%% @doc Parse an IPv4 Address with an optionally specified port.
%% The default port will be substituted in if not given.
-spec parse_ipv4_address_with_port(binary()|list(), inet:port_number()) -> {inet:ip4_address(), inet:port_number()}.
parse_ipv4_address_with_port(Value, DefaultPort) ->
    case re:split(Value, ":") of
        [IP, Port] -> {parse_ipv4_address(IP), parse_port(Port)};
        [IP] -> {parse_ipv4_address(IP), DefaultPort}
    end.

%%====================================================================
%% Internal functions
%%====================================================================

-spec parse_port(binary()|list()) -> inet:port_number().
parse_port(Port) when is_binary(Port) ->
    binary_to_integer(Port);
parse_port(Port) when is_list(Port) ->
    list_to_integer(Port).

maybe_start_tcp_listener() ->
    case spartan_config:tcp_enabled() of
        true ->
            IPs = spartan_config:bind_ips(),
            lists:foreach(fun start_tcp_listener/1, IPs);
        false ->
            ok
    end.

start_tcp_listener(IP) ->
    Port = spartan_config:tcp_port(),
    Acceptors = 100,
    Options = [{port, Port}, {ip, IP}],
    {ok, _} = ranch:start_listener({?TCP_LISTENER_NAME, IP},
        Acceptors,
        ranch_tcp,
        Options,
        spartan_tcp_handler,
        []).

% A normal configuration would look something like:
%  {
%    "upstream_resolvers": ["169.254.169.253"],
%    "udp_port": 53,
%    "tcp_port": 53
%  }
maybe_load_json_config() ->
    case file:read_file("/opt/mesosphere/etc/spartan.json") of
        {ok, FileBin} ->
            load_json_config(FileBin);
        _ ->
            ok
    end.

load_json_config(FileBin) ->
    ConfigMap = jsx:decode(FileBin, [return_maps]),
    ConfigTuples = maps:to_list(ConfigMap),
    lists:foreach(fun process_config_tuple/1, ConfigTuples).

process_config_tuple({<<"upstream_resolvers">>, UpstreamResolvers}) ->
    UpstreamIPsAndPorts = lists:map(fun (Resolver) -> parse_ipv4_address_with_port(Resolver, 53) end, UpstreamResolvers),
    application:set_env(?APP, upstream_resolvers, UpstreamIPsAndPorts);
process_config_tuple({Key, Value}) when is_binary(Value) ->
    application:set_env(?APP, binary_to_atom(Key, utf8), binary_to_list(Value));
process_config_tuple({Key, Value}) ->
    application:set_env(?APP, binary_to_atom(Key, utf8), Value).

%%====================================================================
%% Unit Tests
%%====================================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

parse_ipv4_addres_with_port_test() ->
    %% With explicit port
    ?assert({{127, 0, 0, 1}, 9000} == parse_ipv4_address_with_port("127.0.0.1:9000", 42)),
    %% Fallback to default
    ?assert({{8, 8, 8, 8}, 12345} == parse_ipv4_address_with_port("8.8.8.8", 12345)).

-endif.
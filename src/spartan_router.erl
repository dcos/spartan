-module(spartan_router).
-author("sdhillon").

-include("spartan.hrl").

-include_lib("dns/include/dns_terms.hrl").
-include_lib("dns/include/dns_records.hrl").

%% API
-export([upstreams_from_questions/1]).

%% @doc Resolvers based on a set of "questions"
-spec(upstreams_from_questions(dns:questions()) -> ordsets:ordset(upstream())).
upstreams_from_questions([#dns_query{name=Name}]) ->
    LowerName = dns:dname_to_lower(Name),
    Labels = dns:dname_to_labels(LowerName),
    ReversedLabels = lists:reverse(Labels),
    lists:map(fun normalize_ip/1, find_upstream(Name, ReversedLabels));

%% There is more than one question. This is beyond our capabilities at the moment
upstreams_from_questions([Question|Others]) ->
    spartan_metrics:update([spartan, ignored_questions], length(Others), ?COUNTER),
    upstreams_from_questions([Question]).

%% @private
normalize_ip({NS, Port}) when is_list(NS) ->
    {ok, IP} = inet:parse_ipv4_address(NS),
    {IP, Port};
normalize_ip({IP, Port}) when is_tuple(IP) andalso is_integer(Port) ->
    {IP, Port};
normalize_ip(NS) when is_list(NS) ->
    normalize_ip({NS, 53});
normalize_ip(NS) when is_binary(NS) ->
    normalize_ip(binary_to_list(NS)).

%% @private
mesos_resolvers() ->
    application:get_env(?APP, mesos_resolvers, []).

%% This one is a little bit more complicated...
%% @private
erldns_resolvers() ->
    ErlDNSServers = application:get_env(erldns, servers, []),
    retrieve_servers(ErlDNSServers, []).
retrieve_servers([], Acc) ->
    Acc;
retrieve_servers([Config|Rest], Acc) ->
    case {
            inet:parse_ipv4_address(proplists:get_value(address, Config, "")),
            proplists:get_value(port, Config),
            proplists:get_value(family, Config)
    } of
        {_, undefined, _} ->
            retrieve_servers(Rest, Acc);
        {{ok, Address}, Port, inet} when is_integer(Port) ->
            retrieve_servers(Rest, [{Address, Port}|Acc]);
        _ ->
            retrieve_servers(Rest, Acc)
    end.

%% @private
default_resolvers() ->
    Defaults = [{"8.8.8.8", 53},
                {"4.2.2.1", 53},
                {"8.8.8.8", 53},
                {"4.2.2.1", 53},
                {"8.8.8.8", 53}],
    application:get_env(?APP, upstream_resolvers, Defaults).

%% @private
-spec(find_upstream(Name :: binary(), Labels :: [binary()]) -> [{string(), inet:port_number()}]).
find_upstream(Name, Z = [<<"mesos">>|_]) ->
    lager:debug("find_upstream mesos: ~p ~p", [Name, Z]),
    mesos_resolvers();
find_upstream(Name, Z = [<<"zk">>|_]) ->
    lager:debug("find_upstream zk: ~p ~p", [Name, Z]),
    erldns_resolvers();
find_upstream(Name, Z = [<<"spartan">>|_]) ->
    lager:debug("find_upstream spartan: ~p ~p", [Name, Z]),
    erldns_resolvers();
find_upstream(Name, Labels) ->
    lager:debug("find_upstream upstream: ~p ~p", [Name, Labels]),
    case erldns_zone_cache:get_authority(Name) of
        {ok, SOA} ->
            lager:debug("find_upstream soa: ~p", [SOA]),
            erldns_resolvers();
        _ ->
            lager:debug("find_upstream default resolvers"),
            default_resolvers()
    end.

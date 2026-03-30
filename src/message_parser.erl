-module(message_parser).
-include_lib("kernel/include/logger.hrl").
-export([parse/1]).

parse(Msg) when is_binary(Msg) ->
    MapData = jsx:decode(Msg),
    internal_parse(MapData);
parse(Msg) when is_list(Msg) ->
    MapData = jsx:decode(list_to_binary(Msg)),
    internal_parse(MapData).

% HELLO event
internal_parse(#{<<"op">> := 10, 
                 <<"d">> := #{<<"heartbeat_interval">> := HBInterval}}) ->
    ?LOG_INFO("HELLO event triggered, with heartbeat interval: ~p", [HBInterval]),
    ok;
internal_parse(Msg) ->
    ?LOG_WARNING("unexpected message to parse: ~p", [Msg]),
    ok.

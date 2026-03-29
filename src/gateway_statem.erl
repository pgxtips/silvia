-module(gateway_statem).

-export([parse_wss_url/1]).

-include_lib("kernel/include/logger.hrl").
-behaviour(gen_statem).

%%% gen_statem callbacks
-export([init/1]).
-export([callback_mode/0]).
-export([terminate/3]).
-export([start_link/1]).
-export([establish_websocket/3]).
-export([connected/3]).

start_link([WSSUrl]) ->
    gen_statem:start({local, ?MODULE}, ?MODULE, [WSSUrl], []).

%%% gen_statem callbacks
init([WSSUrl]) ->
    ?LOG_DEBUG("WSS Url: ~p", [WSSUrl]),
    Data = #{wss_url => WSSUrl},
    {ok, establish_websocket, Data, [{next_event, internal, connect}]}.

callback_mode() -> state_functions.

terminate(Reason, State, Data) ->
    ?LOG_ERROR("Reason: ~p, State: ~p, Data: ~p", [Reason, State, Data]),
    ok.

%% ---------------
%% state functions
%% ---------------

%% ---------------
%% state: establish_websocket
%% attempts to make successful websocket connection to discord gateway
%% ---------------
establish_websocket(internal, connect, Data) ->
    Url = maps:get(wss_url, Data),
    ?LOG_DEBUG("Connecting to ~p", [Url]),

    #{host := Host, port := Port, path := Path, qs := Qs} = parse_wss_url(Url),
    ?LOG_DEBUG("Connecting to ~p:~p~s~s", [Host, Port, Path, Qs]),
    
    case gun:open(Host, Port, #{ transport => tls, protocols => [http] }) of
        {ok, ConnPid} ->
            NewData = Data#{
                conn_pid => ConnPid,
                host => Host,
                port => Port,
                path => Path,
                qs => Qs
            },
            {keep_state, NewData};
        {error, Reason} ->
            ?LOG_ERROR("gun:open failed: ~p", [Reason]),
            {keep_state, Data, [{state_timeout, 5000, retry_connect}]}
    end;

%% gun_up message is sent end upon successful connection to the source
establish_websocket(info, {gun_up, ConnPid, http}, Data = #{conn_pid := ConnPid}) ->
    ?LOG_DEBUG("Gun connection is up"),
    {keep_state, Data, [{next_event, internal, ws_upgrade}]};

%% once successful connection has been established (via gun_up message),
%% then perform a websocket upgrade
establish_websocket(internal, ws_upgrade, Data = #{conn_pid := ConnPid, path := Path, qs := Qs}) ->
    FullPath = Path ++ Qs,
    ?LOG_DEBUG("Upgrading websocket on path: ~s", [FullPath]),

    StreamRef = gun:ws_upgrade(ConnPid, FullPath),
    NewData = Data#{stream_ref => StreamRef},
    {keep_state, NewData};

%% gun_upgrade message is sent upon success
establish_websocket(info, {gun_upgrade, ConnPid, StreamRef, [<<"websocket">>], _Headers},
                    Data = #{conn_pid := ConnPid, stream_ref := StreamRef}) ->
    ?LOG_INFO("WebSocket upgrade successful"),
    {next_state, connected, Data};

%% receiving a message at this point means that the upgrade has failed
%% the best course of action is to close the connection and try again
establish_websocket(info, {gun_response, ConnPid, StreamRef, _Fin, Status, Headers},
                    Data = #{conn_pid := ConnPid, stream_ref := StreamRef}) ->
    ?LOG_ERROR("WebSocket upgrade failed, status=~p headers=~p", [Status, Headers]),
    gun:close(ConnPid),
    RetryData = clear_conn_data(Data),
    {keep_state, RetryData, [{state_timeout, 5000, retry_connect}]};

%% a gun_down means that the gun process as died at some point during this process
%% the best course of action is to close the connection and try again
establish_websocket(info, {gun_down, ConnPid, _Protocol, Reason, _KilledStreams}, Data) ->
    case maps:get(conn_pid, Data, undefined) of
        ConnPid ->
            ?LOG_WARNING("Connection went down during websocket establishment: ~p", [Reason]),
            RetryData = clear_conn_data(Data),
            {keep_state, RetryData, [{state_timeout, 5000, retry_connect}]};
        _ ->
            {keep_state, Data}
    end;

establish_websocket(state_timeout, retry_connect, Data) ->
    {keep_state, Data, [{next_event, internal, connect}]};

establish_websocket(info, Msg, Data) ->
    ?LOG_DEBUG("Unhandled establish_websocket info msg: ~p", [Msg]),
    {keep_state, Data};

establish_websocket(_EventType, _EventContent, Data) ->
    {keep_state, Data}.


%% ---------------
%% state: connected
%% handles requests via the socket connection
%% ---------------
%% handles outbound websocket messages
connected(cast, {send_payload, Payload}, Data = #{conn_pid := ConnPid, stream_ref := StreamRef}) ->
    ?LOG_DEBUG("Sending payload: ~p", [Payload]),
    ok = gun:ws_send(ConnPid, StreamRef, {text, Payload}),
    {keep_state, Data};

%% handles inbound websocket TEXT messages
connected(info, {gun_ws, ConnPid, StreamRef, {text, Msg}},
          Data = #{conn_pid := ConnPid, stream_ref := StreamRef}) ->
    ?LOG_DEBUG("Received websocket text msg: ~s", [Msg]),
    {keep_state, Data};

%% handles inbound websocket BINARY messages
connected(info, {gun_ws, ConnPid, StreamRef, {binary, Msg}},
          Data = #{conn_pid := ConnPid, stream_ref := StreamRef}) ->
    ?LOG_DEBUG("Received websocket binary msg: ~p", [Msg]),
    {keep_state, Data};

%% handles inbound websocket CLOSE socket frames
connected(info, {gun_ws, ConnPid, StreamRef, close},
          Data = #{conn_pid := ConnPid, stream_ref := StreamRef}) ->
    ?LOG_WARNING("Websocket close frame received"),
    RetryData = clear_conn_data(Data),
    {next_state, establish_websocket, RetryData,
    [{state_timeout, 5000, retry_connect}]};
 
%% handles the termination of a gun process for a given reason
connected(info, {gun_down, ConnPid, _Protocol, Reason, _KilledStreams}, Data) ->
    case maps:get(conn_pid, Data, undefined) of
        ConnPid ->
            ?LOG_WARNING("Connection down: ~p", [Reason]),
            RetryData = clear_conn_data(Data),
            {next_state, establish_websocket, RetryData,
            [{state_timeout, 5000, retry_connect}]};
        _ ->
            {keep_state, Data}
    end;

connected(info, Msg, Data) ->
    ?LOG_DEBUG("Unhandled connected info msg: ~p", [Msg]),
    {keep_state, Data};

connected(_EventType, _EventContent, Data) ->
    {keep_state, Data}.

%% ---------------
%% internal functions
%% ---------------
parse_wss_url(Url) ->
    Map = uri_string:parse(Url),

    Scheme = maps:get(scheme, Map),
    Host = maps:get(host, Map),
    Path = maps:get(path, Map, "/"),
    Query = maps:get(query, Map, undefined),

    Port = case maps:get(port, Map, undefined) of
        undefined when Scheme =:= "wss" -> 443;
        undefined when Scheme =:= "ws" -> 80;
        P -> P
    end,

    Qs = case Query of
        undefined -> "";
        "" -> "";
        Q -> "?" ++ Q
    end,
    
    #{host => Host, port => Port, path => Path, qs => Qs}.

clear_conn_data(Data) ->
    maps:without([conn_pid, stream_ref], Data).

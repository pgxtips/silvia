-module(gateway_statem).

-include_lib("kernel/include/logger.hrl").
-behaviour(gen_statem).

%%% gen_statem callbacks
-export([init/1]).
-export([callback_mode/0]).
-export([state_name/3]).
-export([handle_event/4]).
-export([terminate/3]).
-export([start_link/1]).

start_link([WSSUrl]) ->
    ?LOG_DEBUG("WSS Url: ~s", [WSSUrl]),
    gen_statem:start({local, ?MODULE}, ?MODULE, [], [WSSUrl]).

%%% gen_statem callbacks
init([WSSUrl]) ->
  error(not_implemented).

-spec callback_mode() -> state_functions.
callback_mode() -> state_functions.

state_name(_, _, _) ->
  error(not_implemented).

handle_event(_, _, _, _) ->
  error(not_implemented).

terminate(_, _, _) ->
  error(not_implemented).

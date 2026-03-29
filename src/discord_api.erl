-module(discord_api).

-include_lib("kernel/include/logger.hrl").

-export([open_gateway/0]).

open_gateway() ->
    BotToken = os:getenv("DISCORD_BOT_TOKEN"),
    RequestURL = "https://discord.com/api/v10/gateway/bot",
    RequestHeaders = [
        {"Authorization", io_lib:format("Bot ~s", [BotToken])}
    ],
    HttpOpts = [
        {ssl, [{verify, verify_none}]}
    ],
    Response = httpc:request(get, {RequestURL, RequestHeaders}, HttpOpts, []),
    case Response of
        {ok, {{_, 200, _}, _Headers, Body}} -> 
            ?LOG_DEBUG("Response ok: ~s", [Body]),
            {ok, Body};
        {ok, {{_, Status, _}, Headers, Body}} ->
            Error = io:format("HTTP error ~p~nHeaders: ~p~nBody: ~s~n", [Status, Headers, Body]),
            ?LOG_DEBUG("Response error: ~s", [Error]),
            {error, Error};
        {error, Reason} ->
            Error = io:format("Request failed: ~p~n", [Reason]),
            {error, Error}
    end.

%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%

-module(negative_test_util).

-include("amqp_client_internal.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

non_existent_exchange_test() ->
    {ok, Connection} = test_util:new_connection(),
    X = <<"test">>,
    RoutingKey = <<"a">>,
    Payload = <<"foobar">>,
    {ok, Channel} = amqp_connection:open_channel(Connection),
    {ok, OtherChannel} = amqp_connection:open_channel(Connection),
    amqp_channel:call(Channel, #'exchange.declare'{exchange = X}),

    %% Deliberately mix up the routingkey and exchange arguments
    Publish = #'basic.publish'{exchange = RoutingKey, routing_key = X},
    amqp_channel:call(Channel, Publish, #amqp_msg{payload = Payload}),
    test_util:wait_for_death(Channel),

    %% Make sure Connection and OtherChannel still serve us and are not dead
    {ok, _} = amqp_connection:open_channel(Connection),
    amqp_channel:call(OtherChannel, #'exchange.delete'{exchange = X}),
    amqp_connection:close(Connection).

bogus_rpc_test() ->
    {ok, Connection} = test_util:new_connection(),
    {ok, Channel} = amqp_connection:open_channel(Connection),
    %% Deliberately bind to a non-existent queue
    Bind = #'queue.bind'{exchange    = <<"amq.topic">>,
                         queue       = <<"does-not-exist">>,
                         routing_key = <<>>},
    try amqp_channel:call(Channel, Bind) of
        _ -> exit(expected_to_exit)
    catch
        exit:{{shutdown, {server_initiated_close, Code, _}},_} ->
            ?assertMatch(?NOT_FOUND, Code)
    end,
    test_util:wait_for_death(Channel),
    ?assertMatch(true, is_process_alive(Connection)),
    amqp_connection:close(Connection).

hard_error_test() ->
    {ok, Connection} = test_util:new_connection(),
    {ok, Channel} = amqp_connection:open_channel(Connection),
    {ok, OtherChannel} = amqp_connection:open_channel(Connection),
    OtherChannelMonitor = erlang:monitor(process, OtherChannel),
    Qos = #'basic.qos'{prefetch_size = 10000000},
    try amqp_channel:call(Channel, Qos) of
        _ -> exit(expected_to_exit)
    catch
        exit:{{shutdown, {connection_closing,
                          {server_initiated_close, ?NOT_IMPLEMENTED, _}}}, _} ->
            ok
    end,
    receive
        {'DOWN', OtherChannelMonitor, process, OtherChannel, OtherExit} ->
            ?assertMatch({shutdown,
                          {connection_closing,
                           {server_initiated_close, ?NOT_IMPLEMENTED, _}}},
                         OtherExit)
    end,
    test_util:wait_for_death(Channel),
    test_util:wait_for_death(Connection).

%% The connection should die if the underlying connection is prematurely
%% closed. For a network connection, this means that the TCP socket is
%% closed. For a direct connection (remotely only, of course), this means that
%% the RabbitMQ node appears as down.
connection_failure_test() ->
    {ok, Connection} = test_util:new_connection(),
    case amqp_connection:info(Connection, [type, amqp_params]) of
        [{type, direct}, {amqp_params, Params}]  ->
            case Params#amqp_params_direct.node of
                N when N == node() ->
                    amqp_connection:close(Connection);
                N ->
                    true = erlang:disconnect_node(N),
                    net_adm:ping(N)
            end;
        [{type, network}, {amqp_params, _}] ->
            [{sock, Sock}] = amqp_connection:info(Connection, [sock]),
            ok = gen_tcp:close(Sock)
    end,
    test_util:wait_for_death(Connection),
    ok.

%% An error in a channel should result in the death of the entire connection.
%% The death of the channel is caused by an error in generating the frames
%% (writer dies)
channel_writer_death_test() ->
    {ok, Connection} = test_util:new_connection(),
    {ok, Channel} = amqp_connection:open_channel(Connection),
    Publish = #'basic.publish'{routing_key = <<>>, exchange = <<>>},
    QoS = #'basic.qos'{prefetch_count = 0},
    Message = #amqp_msg{props = <<>>, payload = <<>>},
    amqp_channel:cast(Channel, Publish, Message),
    ?assertExit(_, amqp_channel:call(Channel, QoS)),
    test_util:wait_for_death(Channel),
    test_util:wait_for_death(Connection),
    ok.

%% An error in the channel process should result in the death of the entire
%% connection. The death of the channel is caused by making a call with an
%% invalid message to the channel process
channel_death_test() ->
    {ok, Connection} = test_util:new_connection(),
    {ok, Channel} = amqp_connection:open_channel(Connection),
    ?assertExit(_, amqp_channel:call(Channel, bogus_message)),
    test_util:wait_for_death(Channel),
    test_util:wait_for_death(Connection),
    ok.

%% Attempting to send a shortstr longer than 255 bytes in a property field
%% should fail - this only applies to the network case
shortstr_overflow_property_test() ->
    {ok, Connection} = test_util:new_connection(just_network),
    {ok, Channel} = amqp_connection:open_channel(Connection),
    SentString = << <<"k">> || _ <- lists:seq(1, 340)>>,
    #'queue.declare_ok'{queue = Q}
        = amqp_channel:call(Channel, #'queue.declare'{exclusive = true}),
    Publish = #'basic.publish'{exchange = <<>>, routing_key = Q},
    PBasic = #'P_basic'{content_type = SentString},
    AmqpMsg = #amqp_msg{payload = <<"foobar">>, props = PBasic},
    QoS = #'basic.qos'{prefetch_count = 0},
    amqp_channel:cast(Channel, Publish, AmqpMsg),
    ?assertExit(_, amqp_channel:call(Channel, QoS)),
    test_util:wait_for_death(Channel),
    test_util:wait_for_death(Connection),
    ok.

%% Attempting to send a shortstr longer than 255 bytes in a method's field
%% should fail - this only applies to the network case
shortstr_overflow_field_test() ->
    {ok, Connection} = test_util:new_connection(just_network),
    {ok, Channel} = amqp_connection:open_channel(Connection),
    SentString = << <<"k">> || _ <- lists:seq(1, 340)>>,
    #'queue.declare_ok'{queue = Q}
        = amqp_channel:call(Channel, #'queue.declare'{exclusive = true}),
    ?assertExit(_, amqp_channel:call(
                       Channel, #'basic.consume'{queue = Q,
                                                 no_ack = true,
                                                 consumer_tag = SentString})),
    test_util:wait_for_death(Channel),
    test_util:wait_for_death(Connection),
    ok.

%% Simulates a #'connection.open'{} method received on non-zero channel. The
%% connection is expected to send a '#connection.close{}' to the server with
%% reply code command_invalid
command_invalid_over_channel_test() ->
    {ok, Connection} = test_util:new_connection(),
    {ok, Channel} = amqp_connection:open_channel(Connection),
    MonitorRef = erlang:monitor(process, Connection),
    case amqp_connection:info(Connection, [type]) of
        [{type, direct}]  -> Channel ! {send_command, #'connection.open'{}};
        [{type, network}] -> gen_server:cast(Channel,
                                 {method, #'connection.open'{}, none, noflow})
    end,
    assert_down_with_error(MonitorRef, command_invalid),
    ?assertNot(is_process_alive(Channel)),
    ok.

%% Simulates a #'basic.ack'{} method received on channel zero. The connection
%% is expected to send a '#connection.close{}' to the server with reply code
%% command_invalid - this only applies to the network case
command_invalid_over_channel0_test() ->
    {ok, Connection} = test_util:new_connection(just_network),
    gen_server:cast(Connection, {method, #'basic.ack'{}, none, noflow}),
    MonitorRef = erlang:monitor(process, Connection),
    assert_down_with_error(MonitorRef, command_invalid),
    ok.

assert_down_with_error(MonitorRef, CodeAtom) ->
    receive
        {'DOWN', MonitorRef, process, _, Reason} ->
            {shutdown, {server_misbehaved, Code, _}} = Reason,
            ?assertMatch(CodeAtom, ?PROTOCOL:amqp_exception(Code))
    after 2000 ->
        exit(did_not_die)
    end.

non_existent_user_test() ->
    Params = [{username, <<"no-user">>}, {password, <<"no-user">>}],
    ?assertMatch({error, {auth_failure, _}}, test_util:new_connection(Params)).

invalid_password_test() ->
    Params = [{username, <<"guest">>}, {password, <<"bad">>}],
    ?assertMatch({error, {auth_failure, _}}, test_util:new_connection(Params)).

non_existent_vhost_test() ->
    Params = [{virtual_host, <<"oops">>}],
    ?assertMatch({error, not_allowed}, test_util:new_connection(Params)).

no_permission_test() ->
    Params = [{username, <<"test_user_no_perm">>},
              {password, <<"test_user_no_perm">>}],
    ?assertMatch({error, not_allowed}, test_util:new_connection(Params)).

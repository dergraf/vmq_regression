-module(vmq_test_utils).
-include_lib("vmq_commons/include/vmq_types.hrl").

-export([setup_client/3, wait_for_pid/1,
         start_server/2, stop_server/2]).




setup_client(Config, Type, Opts) ->
    %% Type = sub/pub
    %% Opts = MQTTConnectOpts, TCPConnectOpts and ConfigOpts
    %% ConfigOpts =
    %%   pub: iterations           : nr of messages each publisher sends
    %%        interval             : nr of milliseconds to sleep between publish
    %%        qos                  : qos used to publish a message
    %%        topic_gen            : function to generate a topic string
    %%        payload_gen          : function to generate a payload binary
    %%   sub: qos                  : qos used to subscribe
    %%        topic_gen            : function to generate a topic string
    %%        stop_after_n_msgs    : stop subscriber after it has received n msgs
    %%        stop_after_n_ms      : stop subscriber after n milliseconds have passed
    %%
    %% ConnectOpts =
    %%  hostname                   : default localhost
    %%  port                       : default 1888
    %%  timeout                    : connect timeout, default 60000
    %%
    %% MQTTOpts =
    %%  clean_session              : default true
    %%  keepalive                  : default 60 seconds
    %%  username
    %%  password
    %%  proto_ver                  : default 3
    %%  will_topic
    %%  will_qos
    %%  will_retain
    %%  will_msg
    spawn_link(
      fun() ->
              ClientIdGen = proplists:get_value(clientid_gen, Opts,
                                                fun() ->
                                                        "client-" ++ pid_to_list(self())
                                                end),
              ClientId = ClientIdGen(),
              Connect = packet:gen_connect(ClientId, Opts),
              Connack = packet:gen_connack(),
              case packet:do_client_connect(Connect, Connack, Opts) of
                  {ok, Socket} when Type == pub ->
                      N = proplists:get_value(iterations, Opts, 100),
                      Interval = proplists:get_value(interval, Opts, 1000),
                      QoS = proplists:get_value(qos, Opts, 0),
                      TopicGen = proplists:get_value(topic_gen, Opts,
                                                 fun(_ClientId) -> "a/b/c" end),
                      PayloadGen = proplists:get_value(payload_gen, Opts,
                                                       fun(_ClientId) -> crypto:rand_bytes(128) end),
                      send_loop(Socket, N, Interval, PayloadGen(ClientId),
                                TopicGen(ClientId), QoS);
                  {ok, Socket} when Type == sub ->
                      QoS = proplists:get_value(qos, Opts, 0),
                      TopicGen = proplists:get_value(topic_gen, Opts,
                                                 fun(_ClientId) -> "a/b/c" end),
                      NrMsgs = proplists:get_value(stop_after_n_msgs, Opts, 1000),
                      Timeout = proplists:get_value(stop_after_n_ms, Opts, 60000),
                      erlang:send_after(Timeout, self(), timetrap),
                      recv_loop(Config, Socket, NrMsgs, TopicGen(ClientId), QoS);
                  {error, Reason} ->
                      exit(Reason)
              end
      end).


recv_loop(Config, Socket, N, Topic, QoS) ->
    Mid = next_mid(),
    Sub = packet:gen_subscribe(Mid, [{Topic, QoS}]),
    Ack = packet:gen_suback(Mid, QoS),
    tcp_send(Socket, Sub),
    case packet:expect_packet(Socket, suback, Ack) of
        ok ->
            recv_loop_(Config, Socket, <<>>, N);
        {error, Reason} ->
            exit(Reason)
    end.
recv_loop_(Config, Socket, Buf, N) when N > 0 ->
    inet:setopts(Socket, [{active, once}]),
    receive
        timetrap ->
            gen_tcp:close(Socket),
            exit(timetrap);
        {tcp, Socket, Data} ->
            process_frame(Config, Socket, <<Buf/binary, Data/binary>>, N);
        {tcp_error, Socket, Reason} ->
            exit(Reason);
        {tcp_closed, Socket} ->
            exit(closed_by_server);
        O ->
            exit({unknown_message, O})
    end;
recv_loop_(_, Socket, _, _) ->
    gen_tcp:close(Socket).

process_frame(Config, Socket, Data, N) ->
    case vmq_parser:parse(Data) of
        {error, Reason} ->
            exit(Reason);
        more ->
            recv_loop_(Config, Socket, Data, N);
        {#mqtt_publish{qos=0, payload=Payload}, Rest} ->
            TS2 = os:timestamp(),
            {TS1, _} = binary_to_term(Payload),
            Lat = timer:now_diff(TS2, TS1),
            SampleType = proplists:get_value(sample_type, Config, publish0),
            vmq_regression_TEST:sample(Config, SampleType, Lat),
            process_frame(Config, Socket, Rest, N - 1);
        {#mqtt_publish{qos=1, message_id=Mid, payload=Payload}, Rest} ->
            {TS1, _} = binary_to_term(Payload),
            Ack = packet:gen_puback(Mid),
            tcp_send(Socket, Ack),
            TS2 = os:timestamp(),
            Lat = timer:now_diff(TS2, TS1),
            SampleType = proplists:get_value(sample_type, Config, publish1),
            vmq_regression_TEST:sample(Config, SampleType, Lat),
            process_frame(Config, Socket, Rest, N - 1);
        {#mqtt_publish{qos=2, message_id=Mid, payload=Payload}, Rest} ->
            {TS1, _} = binary_to_term(Payload),
            Rec = packet:gen_pubrec(Mid),
            Rel = packet:gen_pubrel(Mid),
            Cmp = packet:gen_pubcomp(Mid),
            tcp_send(Socket, Rec),
            case packet:expect_packet(Socket, pubrel, Rel) of
                ok ->
                    tcp_send(Socket, Cmp);
                {error, Reason} ->
                    exit(Reason)
            end,
            TS2 = os:timestamp(),
            Lat = timer:now_diff(TS2, TS1),
            SampleType = proplists:get_value(sample_type, Config, publish2),
            vmq_regression_TEST:sample(Config, SampleType, Lat),
            process_frame(Config, Socket, Rest, N - 1)
    end.

send_loop(Socket, 0, _, _, _, _) -> gen_tcp:close(Socket);
send_loop(Socket, N, Interval, Payload, Topic, 0) ->
    Bin = term_to_binary({os:timestamp(), Payload}),
    Pub = packet:gen_publish(Topic, 0, Bin, []),
    tcp_send(Socket, Pub),
    timer:sleep(Interval),
    send_loop(Socket, N - 1, Interval, Payload, Topic, 0);
send_loop(Socket, N, Interval, Payload, Topic, 1) ->
    Bin = term_to_binary({os:timestamp(), Payload}),
    Mid = next_mid(),
    Pub = packet:gen_publish(Topic, 1, Bin, [{mid, Mid}]),
    Ack = packet:gen_puback(Mid),
    tcp_send(Socket, Pub),
    case packet:expect_packet(Socket, puback, Ack) of
        ok ->
            timer:sleep(Interval),
            send_loop(Socket, N - 1, Interval, Payload, Topic, 1);
        {error, Reason} ->
            gen_tcp:close(Socket),
            exit(Reason)
    end;
send_loop(Socket, N, Interval, Payload, Topic, 2) ->
    Bin = term_to_binary({os:timestamp(), Payload}),
    Mid = next_mid(),
    Pub = packet:gen_publish(Topic, 2, Bin, [{mid, Mid}]),
    Rec = packet:gen_pubrec(Mid),
    Rel = packet:gen_pubrel(Mid),
    Cmp = packet:gen_pubcomp(Mid),
    tcp_send(Socket, Pub),
    case packet:expect_packet(Socket, pubrec, Rec) of
        ok ->
            tcp_send(Socket, Rel),
            case packet:expect_packet(Socket, pubcomp, Cmp) of
                ok ->
                    timer:sleep(Interval),
                    send_loop(Socket, N - 1, Interval, Payload, Topic, 2);
                {error, Reason} ->
                    gen_tcp:close(Socket),
                    exit(Reason)
            end;
        {error, Reason} ->
            gen_tcp:close(Socket),
            exit(Reason)
    end.

tcp_send(Socket, Bin) ->
    case gen_tcp:send(Socket, Bin) of
        ok -> ok;
        {error, Reason} ->
            gen_tcp:close(Socket),
            exit(Reason)
    end.

next_mid() ->
    case get(mid) of
        undefined -> put(mid, 1), 1;
        Mid when Mid < 65535 -> erase(mid), next_mid();
        Mid -> NewMid = Mid + 1, put(mid, NewMid), NewMid
    end.


wait_for_pid(Pid) ->
    case is_process_alive(Pid) of
        true ->
            timer:sleep(1000),
            wait_for_pid(Pid);
        false -> ok
    end.

start_server(Case, Config) ->
    Node = proplists:get_value(node, Config),
    PrivDir = proplists:get_value(priv_dir, Config),
    NodeDir = filename:join([PrivDir, Node, Case]),
    ok = rpc:call(Node, application, load, [vmq_server]),
    ok = rpc:call(Node, application, load, [vmq_plugin]),
    ok = rpc:call(Node, application, load, [plumtree]),
    ok = rpc:call(Node, application, load, [lager]),
    ok = rpc:call(Node, application, set_env, [lager,
                                               log_root,
                                               NodeDir]),
    ok = rpc:call(Node, application, set_env, [plumtree,
                                               plumtree_data_dir,
                                               NodeDir]),
    ok = rpc:call(Node, application, set_env, [plumtree,
                                               metadata_root,
                                               NodeDir ++ "/meta/"]),
    ok = rpc:call(Node, application, set_env, [vmq_server,
                                               listeners,
                                               [{vmq, [{{{127,0,0,1},
                                                         32123},
                                                        []}]}
                                               ]]),
    ok = rpc:call(Node, application, set_env, [vmq_server,
                                               msg_store_opts,
                                               [{store_dir,
                                                 NodeDir++"/msgstore"}]
                                              ]),
    ok = rpc:call(Node, application, set_env, [vmq_plugin,
                                               wait_for_proc,
                                               vmq_server_sup]),
    ok = rpc:call(Node, application, set_env, [vmq_plugin,
                                               plugin_dir,
                                               NodeDir]),

    {ok, _} = rpc:call(Node, application, ensure_all_started,
                       [vmq_server]),

    {ok, _} = rpc:call(Node, vmq_server_cmd, listener_start, [18883, []]),
    ok = rpc:call(Node, vmq_auth, register_hooks, []),
    [{port, 18883}|Config].

stop_server(_Case, Config) ->
    Node = proplists:get_value(node, Config),
    rpc:call(Node, application, stop, [vmq_server]),
    Config.

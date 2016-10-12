-module(vmq_server_SUITE).
-export([
        init_per_suite/1,
        end_per_suite/1,
        init_per_testcase/2,
        end_per_testcase/2,
        all/0
        ]).
-export([run/1]).

init_per_suite(_) ->
    [{application, vmq_server},
     {src1, {git, "git://github.com/erlio/vmq_server", "master"}},
     {src2, {git, "git://github.com/dergraf/vmq_server", "e2qc-routing-cache"}}].

end_per_suite(Config) -> Config.
init_per_testcase(Case, Config) -> [{test_case, Case}|Config].
end_per_testcase(_Case, Config) -> Config.

all() ->
    [run].

run(Config) ->
    vmq_regression_TEST:run(
      fun vmq_test_utils:start_server/2,
      fun vmq_test_utils:stop_server/2,
      fun test_run/2, Config).

test_run(_Case, Config) ->
    fan_in_run(Config),
    fan_out_run(Config).

fan_in_run(Config) ->
    CConfig = [{sample_type, fan_in}|Config],
    ConPid = vmq_test_utils:setup_client(CConfig, sub, [lists:keyfind(port, 1, Config),
                                                       {qos, 0},
                                                       {keepalive, 0},
                                                       {topic_gen, fun(_) -> "a/b/c" end},
                                                       {stop_after_n_msgs, 100000},
                                                       {stop_after_n_ms, 30000}]),
    timer:sleep(10000),
    lists:foreach(fun(_) ->
                          vmq_test_utils:setup_client(CConfig, pub, [lists:keyfind(port, 1, Config),
                                                                    {iterations, 100},
                                                                    {interval, 100},
                                                                    {qos, 0},
                                                                    {topic_gen, fun(_) -> "a/b/c" end}
                                                                   ])
                  end, lists:seq(1, 1000)),
    vmq_test_utils:wait_for_pid(ConPid).

fan_out_run(Config) ->
    CConfig = [{sample_type, fan_out}|Config],
    ConPids =
    lists:foldl(
      fun(_, Acc) ->
              ConPid = vmq_test_utils:setup_client(CConfig, sub, [lists:keyfind(port, 1, Config),
                                                                 {qos, 0},
                                                                 {keepalive, 0},
                                                                 {topic_gen, fun(_) -> "a/b/c" end},
                                                                 {stop_after_n_msgs, 100},
                                                                 {stop_after_n_ms, 30000}]),
            [ConPid|Acc]
      end, [], lists:seq(1, 1000)),
    timer:sleep(10000),
    vmq_test_utils:setup_client(CConfig, pub, [lists:keyfind(port, 1, Config),
                                              {iterations, 100},
                                              {interval, 100},
                                              {qos, 0},
                                              {topic_gen, fun(_) -> "a/b/c" end}
                                             ]),
    lists:foreach(fun(ConPid) ->
                          vmq_test_utils:wait_for_pid(ConPid)
                  end, ConPids).

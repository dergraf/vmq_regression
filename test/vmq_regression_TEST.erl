-module(vmq_regression_TEST).
-export([
        sample/3,
        run/4
        ]).

setup(Config) ->
    os:cmd(os:find_executable("epmd")++" -daemon"),
    {ok, Hostname} = inet:gethostname(),
    case net_kernel:start([list_to_atom("runner@"++Hostname), shortnames]) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end,
    App = proplists:get_value(application, Config),

    io:format(user, "----------------- ~p -----------------~n", [App]),
    exec:start([]),
    App1Dir = setup(App, lists:keyfind(src1, 1, Config)),
    App2Dir = setup(App, lists:keyfind(src2, 1, Config)),
    {App1Dir, App2Dir, Config}.

setup(App, {Src, {git, Repo, Ref}}) ->
    io:format(user, "===> Cloning ~s...~n", [Repo]),
    Dir = atom_to_list(Src) ++ "/" ++ atom_to_list(App),
    {ok, _} = exec:run("git clone " ++ Repo ++ " " ++ Dir, [sync]),
    {ok, _} = exec:run("cd " ++ Dir ++ " && git checkout " ++ Ref, [sync]),
    Dir.



teardown(Config) ->
    App = proplists:get_value(application, Config),
    ct_slave:stop(App),
    Config.

setup_samples(Config) ->
    SampleLoopPid = sample_loop(),
    [{sample_loop, SampleLoopPid}|Config].

start_node(App, Dir) ->
    AppEbins = filelib:wildcard(Dir ++ "/_build/default/lib/*/ebin"),
    CodePath = lists:filter(fun filelib:is_dir/1, code:get_path() ++ AppEbins),
    NodeConfig = [
        {monitor_master, true},
        {erl_flags, "+K true -smp"},
        {startup_functions, [
            {code, set_path, [CodePath]}
        ]}
    ],
    case ct_slave:start(App, NodeConfig) of
        {ok, Node} -> Node;
        {error, already_started, _Node} ->
            ct_slave:stop(App),
            timer:sleep(1000),
            start_node(App, Dir)
    end.

results(Config) ->
    Self = self(),
    SampleLoopPid = proplists:get_value(sample_loop, Config),
    Ref = make_ref(),
    SampleLoopPid ! {results, Ref, Self},
    receive
        {Ref, Result} ->
            Result
    end.

sample(Config, What, Sample) when is_number(Sample) ->
    SampleLoopPid = proplists:get_value(sample_loop, Config),
    SampleLoopPid ! {sample, What, Sample},
    ok.

sample_loop() ->
    spawn_link(fun() -> sample_loop([]) end).

sample_loop(Samples) ->
    receive
        {sample, What, Sample} when is_number(Sample) ->
            sample_loop(add_sample(What, Sample, Samples));
        {results, Ref, Pid} ->
            Pid ! {Ref, stats(Samples, [])}
    end.

add_sample(What, Sample, Samples) ->
    case lists:keyfind(What, 1, Samples) of
        false ->
            [{What, [Sample]}|Samples];
        {_, WSamples} ->
            lists:keyreplace(What, 1, Samples, {What, [Sample|WSamples]})
    end.

stats([{What, WSamples}|Samples], Acc) ->
    stats(Samples, [{What, bear:get_statistics(WSamples)}|Acc]);
stats([], Acc) -> Acc.

run(SetupFun, TeardownFun, TestFun, Config) ->
    NrOfRuns = proplists:get_value(nr_runs, Config, 10),
    _Results = run(NrOfRuns, SetupFun, TeardownFun, TestFun, Config).

run(NrOfRuns, SetupFun, TeardownFun, TestFun, Config) ->
    {App1Dir, App2Dir, Config1}= setup(Config),
    Result1 = run_(run_1, NrOfRuns, App1Dir, SetupFun, TeardownFun, TestFun, Config1),
    Result2 = run_(run_2, NrOfRuns, App2Dir, SetupFun, TeardownFun, TestFun, Config1),
    Application = proplists:get_value(application, Config),
    {ok, Host} = inet:gethostname(),
    {git, Repo1, Ref1} = proplists:get_value(src1, Config),
    {git, Repo2, Ref2} = proplists:get_value(src2, Config),

    Json = jsx:encode([{run1, Result1}, {run2, Result2}, {application, Application},
                       {src1, [{repo, list_to_binary(Repo1)}, {ref, list_to_binary(Ref1)}]},
                       {src2, [{repo, list_to_binary(Repo2)}, {ref, list_to_binary(Ref2)}]} ,
                       {host, list_to_binary(Host)}
                      ]),
    file:write_file("results.json", Json),
    io:format(user, "---------------------------~n~p~n", [Result1]),
    io:format(user, "---------------------------~n~p~n", [Result2]).

run_(Case, NrOfRuns, Dir, SetupFun, TeardownFun, TestFun, Config0) ->
    try
        App = proplists:get_value(application, Config0),
        io:format(user, "===> Compile ~p (~s)...~n", [App, Dir]),
        {ok, _} = exec:run("cd " ++ Dir ++" && ./rebar3 compile", [sync]),
        lists:foldl(
          fun(_, Acc) ->
                  Node = start_node(App, Dir),
                  Config1 = SetupFun(Case, [{node, Node}|setup_samples(Config0)]),
                  io:format(user, "===> Run tests...", []),
                  TestFun(Case, Config1),
                  io:format(user, " done~n", []),
                  TeardownFun(Case, Config1),
                  teardown(Config1),
                  Results = results(Config1),
                  transform_result(Results, Acc)
          end, [], lists:seq(1, NrOfRuns))
    catch
        E:R ->
            teardown(Config0),
            exit({E, R})
    end.

transform_result([], Acc) -> Acc;
transform_result([{What, Results}|Rest], Acc) ->
    case lists:keyfind(What, 1, Acc) of
        false ->
            transform_result(Rest, [{What, add_type_results(Results, [])}|Acc]);
        {_, TypeResults} ->
            transform_result(Rest, lists:keyreplace(What, 1, Acc,
                                                    {What, add_type_results(Results, TypeResults)}))
    end.

add_type_results([{percentile, Percentiles}|Rest], Existing) ->
    add_type_results(Rest, add_type_results(
                             [{list_to_atom("perc_" ++ integer_to_list(P)), V}
                              || {P, V} <- Percentiles], Existing));
add_type_results([{histogram, _Histogram}|Rest], Existing) ->
    add_type_results(Rest, Existing);
add_type_results([{T, V}|Rest], Existing) ->
    case lists:keyfind(T, 1, Existing) of
        false ->
            add_type_results(Rest, [{T, [V]}|Existing]);
        {_, E} ->
            add_type_results(Rest,
                             lists:keyreplace(T, 1, Existing, {T, [V|E]}))
    end;
add_type_results([], Results) -> Results.

-export([messageTest/0, controlTest/0, extendTest/0]).

% MANY OF THESE TESTS REQUIRE NAMETOPID TABLE
%  [{red, [{white, [white, green]},{blue , [blue]}]},{white, [{red, [blue]},{blue, [green, red]}]},{blue , [{green, [white, green, red]}]},{green, [{red, [red, blue, white]}]}]

extendTest() ->
    RootPid = graphToNetwork([{red, [{white, [white, green]},{blue , [blue]}]},{white, [{red, [blue]},{blue, [green, red]}]},{blue , [{green, [white, green, red]}]},{green, [{red, [red, blue, white]}]}]),
    
    [WhiteTup] = ets:lookup(nameToPid, white),
    {_, WhitePid} = WhiteTup,
    Edges = [{WhitePid, [white, blue, green, red]}],
    extendNetwork (RootPid, 1, green, {yellow, Edges}),
    ets:delete(nameToPid).

messageTest() ->
    RootPid = graphToNetwork([{red, [{white, [white, green]},{blue , [blue]}]},{white, [{red, [blue]},{blue, [green, red]}]},{blue , [{green, [white, green, red]}]},{green, [{red, [red, blue, white]}]}]),
    RootPid ! {message, green, self(), self(), []},
    receive
        {trace, Pid, Trace} ->
            io:format("Pid ~w received trace ~w", [Pid, Trace])
    end,
    ets:delete(nameToPid).

controlTest() ->
    RootPid = graphToNetwork([{red, [{white, [white, green]},{blue , [blue]}]},{white, [{red, [blue]},{blue, [green, red]}]},{blue , [{green, [white, green, red]}]},{green, [{red, [red, blue, white]}]}]),
    [DestTup] = ets:lookup(nameToPid, green),
    {_, DestPid} = DestTup,

    io:format("SEQNUM1~n"),
    RootPid ! {control, self(), self(), 1,
    fun(Name, Table) ->
        %io:format("in controlFun of ~w~n",[Name]),
        [] % no processes spawned
    end},
        
    receive
        {committed, Pid, SeqNum} ->
            io:format("We have committed seqnum ~w using root node ~w~n", [SeqNum, Pid]);
        {abort, Pid, SeqNum} ->
            io:format("We have aborted seqnum ~w using root node ~w~n", [SeqNum, Pid]);
        Msg ->
            io:format("msg is ~w~n", [Msg])
    after
        10000 ->
            true
    end,    

    DestPid ! {control, self(), self(), 2,
        fun(Name, Table) ->
            case Name of
                red -> ets:insert(Table, {redyeet});
                white -> ets:insert(Table, {whiteyeet});
                blue -> ets:insert(Table, {blueyeet});
                green -> ets:insert(Table, {greenyeet})
            end,
            %io:format("in controlFun of ~w~n",[Name]),
            [] % no processes spawned
        end},

    receive
        {committed, Pid2, SeqNum2} ->
            io:format("We have commited seqnum ~w using root node ~w~n", [SeqNum2, Pid2]);
        {abort, Pid2, SeqNum2} ->
            io:format("We have aborted seqnum ~w using root node ~w~n", [SeqNum2, Pid2]);
        Msg2 ->
            io:format("msg is ~w~n", [Msg2])
    after
        10000 ->
            true
    end,
    ets:delete(nameToPid).
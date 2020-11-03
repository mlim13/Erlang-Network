-module(control).
-export([graphToNetwork/1, extendNetwork/4]).
-export([messageTest/0, controlTest/0]).

% graphToNetwork recurses over Graph data structure.
% Example Graph:

%   [{red  , [{white, [white, green]},
%	    {blue , [blue]}]},
%   {white, [{red, [blue]},
%	    {blue, [green, red]}]},
%   {blue , [{green, [white, green, red]}]},
%   {green, [{red, [red, blue, white]}]}
%   ]

%  [{red, [{white, [white, green]},{blue , [blue]}]},{white, [{red, [blue]},{blue, [green, red]}]},{blue , [{green, [white, green, red]}]},{green, [{red, [red, blue, white]}]}]

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

graphToNetwork(Graph) ->
    % Create table for associating pids with node names 
    ets:new(nameToPid, [named_table]),
    Pid = extractRow(Graph), % start by recursively extracting each "row"
    %ets:delete(nameToPid), % explicitly delete since sometimes named table persists after process terminates leading to an exception on next run
    io:format("graphToNetwork done~n"),
    Pid.

extendNetwork(RootPid, SeqNum, From, {NodeName, Edges}) ->
    % Extract the information that will become the routing table for NodeName
    Entry = extractEdgePid(Edges, []),
    % Now, we send RootPid the control message with an appropriate ControlFun
    % Like all non-0 control messages, this will be propagated to every node
    % ControlFun will do all the heavy lifting for the logic required by extendNetwork
    % Different nodes will need to do different things
    RootPid ! {control, self(), self(), SeqNum, 
        fun(Name, Table) ->
            case Name of
                From -> % At From, we need to spawn the new process
                    % spawn new process and send it its routing table
                    Pid = router:start(NodeName),
                    sendInitialControlMessage(Pid, Entry),
                    receiveAck(), % wait for response to ensure our network is correctly set up
                    % Add new process to From's routing table
                    ets:insert(Table, {NodeName, Pid}),
                    Return = [Pid];
                true ->
                    % Directions to get to the new node is the same as the direction to get to From
                    % Therefore, lookup the which pid leads us to From and use that
                    [FromTup] = ets:lookup(Table, From),
                    {_, FromPid} = FromTup,
                    ets:insert(Table, {NodeName, FromPid}),
                    Return = []
            end,
            Return
        end},
    % Now we need to see whether we aborted or committed
    receive
        {committed, RootPid, SeqNum} ->
            Return = true;
        {abort, RootPid, SeqNum} ->
            Return = false
    after
        5000 -> % if a process takes more than 5 seconds to respond, we assume failure
            io:format("extendNetwork failed to receive a response~n"),
            Return = false
    end,
    Return.

extractRow([H|T]) ->
    % H is a tuple of form (for example): {red  , [{white, [white, blue]}]}
    % NodeName is the router process/node that this particular row is representing
    % Edges is a list that captures all the information about that node. It must be recursively parsed
    {NodeName, Edges} = H,
    
    % Once we have extracted the NodeName, start that router process
    Pid = router:start(NodeName),
    ets:insert(nameToPid, {NodeName, Pid}),

    % Recurse first so we can get all the pids associated with their node names
    % Once we have this information, we can proceed to fill out routing tables
    extractRow(T),

    % Recursively extract the information from the "row"
    Entry = extractEdge(Edges, []),
    %io:format("Entry is ~w~n",[Entry]);

    % send the initial control message which sets up the routing table
    sendInitialControlMessage(Pid, Entry),
    receiveAck(), % wait for response to ensure our network is correctly set up
    Pid; % return pid of first node
extractRow([]) ->
    true. % recursion finished

extractEdge([H|T], Entry) ->
    % H|T is of the form [{white, [white, blue]}, {blue, [green]}]
    % ie. a list of information about NodeName's neighbours
    {Dest, Names} = H,
    % Once we have names = [white, blue], we need to recurse over this list
    % The union of every such list will give the total list of all NodeName's neighbours
    NewEntry = extractName(Names, Entry, Dest),
    extractEdge(T, NewEntry); % recurse
extractEdge([], Entry) ->
    Entry. % recursion finished

% this is identical logic to extractEdge except uses extractNamePid rather than extractName
extractEdgePid([H|T], Entry) ->
    % H|T is of the form [{white, [white, blue]}, {blue, [green]}]
    % ie. a list of information about NodeName's neighbours
    {Dest, Names} = H,
    % Once we have names = [white, blue], we need to recurse over this list
    % The union of every such list will give the total list of all NodeName's neighbours
    NewEntry = extractNamePid(Names, Entry, Dest),
    extractEdgePid(T, NewEntry); % recurse
extractEdgePid([], Entry) ->
    Entry. % recursion finished

extractName([H|T], Entry, Dest) ->
    % Join Dest with H to form the entry of the routing table
    [DestTup] = ets:lookup(nameToPid, Dest),
    {_, DestPid} = DestTup,
    NewEntry = lists:append(Entry, [{H, DestPid}]),
    extractName(T, NewEntry, Dest); % recurse
extractName([], Entry, Dest) ->
    Entry.

% this is identical logic to extractName except Dest in this case is already a pid rather than a nodename
extractNamePid([H|T], Entry, Dest) ->
    % Join Dest with H to form the entry of the routing table
    NewEntry = lists:append(Entry, [{H, Dest}]),
    extractNamePid(T, NewEntry, Dest); % recurse
extractNamePid([], Entry, Dest) ->
    Entry.

sendInitialControlMessage(Pid, Entry) ->
    Pid ! {control, self(), self(), 0,
        fun(Name, Table) ->
            ets:insert(Table, Entry),
            [] % no processes spawned
        end}.

receiveAck() ->
    receive
        {committed, Pid, 0} ->
            %io:format("received ack~n"),
            true
    after
        5000 -> % if a process takes more than 5 seconds to respond, we assume failure
            io:format("Initialisation (SeqNum 0) timed out~n")
    end.

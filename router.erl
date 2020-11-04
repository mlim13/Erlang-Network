-module(router).
-export([start/1]).

start(RouterName) ->
    % Spawn with function in this way to avoid needing to export routerReceiverLoop
    spawn(fun() ->
        prologue(RouterName)
     end).

% prologue is used to create a routing table for each spawned process
prologue(RouterName) ->
    % Create routing table data structure
    RoutingTable = ets:new(routingTable, []),
    % Process starts in the ready state
    readyReceive(RouterName, RoutingTable, none, 0).

% ready state is the state where processes exist outside 2pc
% RouterName = name of the router
% RoutingTable = routing table
% Prev = the Pid of the last process to send this process a message (used for 2pc comm)
% LastSeqNum = the sequence number of the most recently received control message
readyReceive(RouterName, RoutingTable, Prev, LastSeqNum) ->
    receive
        % receive message to be routed
        {message, Dest, From, Pid, Trace} ->
            if
                % If we have reached the destination already
                RouterName == Dest ->
                    NewTrace = Trace ++ [RouterName], % append name to trace
                    Pid ! {trace, self(), NewTrace};
                % Otherwise
                true ->    
                    [NextTup] = ets:lookup(RoutingTable, Dest),
                    {_, NextPid} = NextTup, % extract pid to forward to from routing table
                    NewTrace = Trace ++ [RouterName], % append name to trace
                    NextPid ! {message, Dest, self(), Pid, NewTrace} % forward on message
            end,
            readyReceive(RouterName, RoutingTable, Prev, LastSeqNum);
        % receive control message with SeqNum = 0
        {control, From, Pid, 0, ControlFun} ->
            Children = ControlFun(RouterName, RoutingTable),
            From ! {committed, self(), 0}, % send committed straight back to the controller
            io:format("Routing table of ~w is ~w~n",[self(), ets:tab2list(RoutingTable)]),
            readyReceive(RouterName, RoutingTable, none, 0); % reenter receive loop
        % receive control message with the SAME seqnum as the previous
        % this shoud do nothing as the control message is merely a remnant of a previously completed 2pc
        {control, From, Pid, LastSeqNum, ControlFun} ->
            true;
        % receive control message with any other SeqNum. ie. a new control request
        {control, From, Pid, SeqNum, ControlFun} ->
            
            OldTable = ets:tab2list(RoutingTable), % store the old routing table, prior to making changes
            Children = ControlFun(RouterName, RoutingTable), % call ControlFun which makes changes to routing table and might spawn Children
            if
                % if root process
                From == Pid ->
                    % enter a receive loop specific to the root node
                    % waits for votes from all other nodes etc
                    if
                        Children == abort ->
                            From ! {abort, self(), SeqNum};
                        true ->
                            NumNeighbours = sendControlToNeighbours(OldTable, Pid, SeqNum, ControlFun, 0), % propagate control message to all neighbours
                            rootTwoPCReceive(RouterName, RoutingTable, From, SeqNum, OldTable, Children, NumNeighbours, NumNeighbours)
                    end;
                % else
                true ->
                    if
                        Children == abort ->
                            From ! {no, self(), SeqNum};
                        true ->
                            NumNeighbours = sendControlToNeighbours(OldTable, Pid, SeqNum, ControlFun, 0), % propagate control message to all neighbours
                            From ! {yes, self(), SeqNum}, % reply with vote of yes
                            % enter a receive loop waiting to be told whether to doCommit or doAbort
                            twoPCReceive(RouterName, RoutingTable, From, SeqNum, OldTable, Children)
                    end
            end;
        {dump, From} ->
            From ! {table, self (), ets:match (RoutingTable, '$1')},
            readyReceive(RouterName, RoutingTable, Prev, LastSeqNum);
        stop ->
            exit(normal);
        % if we receive a committed message in the ready state, we have already committed the previous 2pc and are simply forwarding other node's acknowledgements
        {committed, From2, SeqNum} ->
            Prev ! {committed, self(), SeqNum},
            readyReceive(RouterName, RoutingTable, Prev, SeqNum);
        % likewise for abort, we need to propagate this onward
        {abort, From2, SeqNum} ->
            if
                % if Prev = none, this node was the root node of the previous 2pc
                % we dont need to propagate the abort message any further as root (self()) already aborted
                Prev == none ->
                    true;
                % if Prev != none, this process was an aborted non-root node. We need to propagate abort messages onto the root
                true ->
                    Prev ! {abort, self(), SeqNum}
            end,
            readyReceive(RouterName, RoutingTable, Prev, SeqNum);
        {doAbort, From2, SeqNum} ->
            From2 ! {abort, self(), SeqNum},
            readyReceive(RouterName, RoutingTable, Prev, LastSeqNum);
        Message ->
            readyReceive(RouterName, RoutingTable, Prev, LastSeqNum)
    end.

% Non-root process's waiting state (waiting for doCommit or doAbort)
% From is the pid of the process who sent this process into this state
twoPCReceive(RouterName, RoutingTable, From, SeqNum, OldTable, Children) ->
    receive
        % If a node is in the 2pc receive state, it has already cast its vote and is waiting to doCommit or doAbort
        {control, From2, Pid, SeqNum2, ControlFun} ->
            if 
                % if a control message with the same seqnum comes in, we ignore it since it is merely a remnant of the initial propagation of control messages
                SeqNum == SeqNum2 ->
                    true;
                % if not, there is another 2pc request happening at the same time
                % to avoid interference, we need to tell this other 2pc to abort
                % NOTE: there is a chance both simultaneous 2pcs will abort
                true ->
                    if
                        % If From2 = Pid, this node is the root node for the simultaneous 2pc
                        % Thus we send an abort straight away to the controller
                        From2 == Pid ->
                            From2 ! {abort, self(), SeqNum2};
                        % Otherwise, we simply reply with a no and let that propagate back to its root
                        true ->
                            From2 ! {no, self(), SeqNum2}
                    end
            end,
            twoPCReceive(RouterName, RoutingTable, From, SeqNum, OldTable, Children);
        % If we receive a yes, we need to propagate this back to the root node
        {yes, From2, SeqNum} ->
            % we want to send the yes back to From (the process that made this process enter this state), not From2 (the process that propagated the yes to this process)
            From ! {yes, self(), SeqNum},
            twoPCReceive(RouterName, RoutingTable, From, SeqNum, OldTable, Children);
        % If we receive a no, we need to propagate it back to the root node
        {no, From2, SeqNum} ->
            From ! {no, self(), SeqNum},
            twoPCReceive(RouterName, RoutingTable, From, SeqNum, OldTable, Children);
        % Receipt of a doCommit
        {doCommit, From2, SeqNum} ->
            NumNeighbours = sendToNeighbours(OldTable, doCommit, SeqNum, 0), % propagate doCommit to all other nodes
            From2 ! {committed, self(), SeqNum}, % reply to the process that told us to commit, with committed
            io:format("Routing table of ~w is ~w~n",[self(), ets:tab2list(RoutingTable)]),
            readyReceive(RouterName, RoutingTable, From2, SeqNum);
        % Receipt of a doAbort
        {doAbort, From2, SeqNum} ->
            NumNeighbours = sendToNeighbours(OldTable, doAbort, SeqNum, 0), % propagate doAbort to all other nodes
            % ROLLBACK
            ets:delete_all_objects(RoutingTable), % Clear the routing table
            ets:insert(RoutingTable, OldTable), % fill the routing table with its old values
            killChildren(Children), % kill children
            From2 ! {abort, self(), SeqNum}, % reply with abort
            io:format("Routing table of ~w is ~w~n",[self(), ets:tab2list(RoutingTable)]),
            readyReceive(RouterName, RoutingTable, From2, SeqNum)
    after
        % If we wait more than 5 seconds, abort
        5000 ->
            From ! {no, self(), SeqNum}
    end.

% Root node enters this state when waiting for votes from all nodes
% From is the process that sent this node into this state (the controller)
% YesCount is used to recursively count how many remaining yes votes are needed
% CommittedCount is used to recursively count how many remaining committed replies are needed
rootTwoPCReceive(RouterName, RoutingTable, From, SeqNum, OldTable, Children, YesCount, CommittedCount) ->
    if
        % If we have received all the yes votes
        YesCount == 0 ->
            NumNeighbours = sendToNeighbours(OldTable, doCommit, SeqNum, 0), % propagate doCommit message
            rootTwoPCCommitted(RouterName, RoutingTable, From, SeqNum, CommittedCount); % enter state waiting for committed acknowledgements
        true ->
            receive
                % if we receive a control message here, it is either a remnant of this 2pc or a new 2pc request
                {control, From2, Pid, SeqNum2, ControlFun} ->
                    if 
                        % if remnant of this 2pc, simply ignore it
                        SeqNum == SeqNum2 ->
                            true;
                        true ->
                            % if it is a new SeqNum, abort it
                            if
                                From2 == Pid ->
                                    From2 ! {abort, self(), SeqNum2};
                                true ->
                                    From2 ! {no, self(), SeqNum2}
                            end
                    end,
                    rootTwoPCReceive(RouterName, RoutingTable, From, SeqNum, OldTable, Children, YesCount, CommittedCount);
                % If we receive a yes, recursively call rootTwoPCReceive with decremented YesCount
                {yes, From2, SeqNum} ->
                    rootTwoPCReceive(RouterName, RoutingTable, From, SeqNum, OldTable, Children, YesCount - 1, CommittedCount);
                % if we receive a no, we know we will have to abort
                {no, From2, SeqNum} ->
                    io:format("~w in no~n",[self()]),
                    NumNeighbours = sendToNeighbours(OldTable, doAbort, SeqNum, 0), % propagate doAbort to all nodes
                    % ROLLBACK
                    ets:delete_all_objects(RoutingTable),
                    ets:insert(RoutingTable, OldTable),
                    killChildren(Children), % kill children
                    rootTwoPCCommitted(RouterName, RoutingTable, From, SeqNum, CommittedCount); % enter state waiting for abort acknowledgements
                % catch any propagated doCommit or doAbort messages and ignore them
                {doCommit, From2, SeqNum} ->
                    rootTwoPCReceive(RouterName, RoutingTable, From, SeqNum, OldTable, Children, YesCount, CommittedCount);
                {doAbort, From2, SeqNum} ->
                    %NumNeighbours = sendToNeighbours(OldTable, doAbort, SeqNum, 0), % propagate doCommit to all other nodes
                    From2 ! {abort, self(), SeqNum},
                    rootTwoPCReceive(RouterName, RoutingTable, From, SeqNum, OldTable, Children, YesCount, CommittedCount)
            after
                % If we wait more than 5 seconds, abort
                5000 ->
                    NumNeighbours = sendToNeighbours(OldTable, doAbort, SeqNum, 0), % propagate doAbort to all nodes
                    % ROLLBACK
                    ets:delete_all_objects(RoutingTable),
                    ets:insert(RoutingTable, OldTable),
                    rootTwoPCCommitted(RouterName, RoutingTable, From, SeqNum, CommittedCount) % enter state waiting for abort acknowledgements
            end
    end.

% Final state that waits for committed or abort acknowledgement/s
rootTwoPCCommitted(RouterName, RoutingTable, From, SeqNum, CommittedCount) ->
    if
        CommittedCount == 0 ->
            From ! {committed, self(), SeqNum},
            io:format("Routing table of ~w is ~w~n",[self(), ets:tab2list(RoutingTable)]),
            readyReceive(RouterName, RoutingTable, none, SeqNum);
        true ->
            receive
                {committed, From2, SeqNum} ->
                    rootTwoPCCommitted(RouterName, RoutingTable, From, SeqNum, CommittedCount - 1);
                {abort, From2, SeqNum} ->
                    io:format("~w in abort. From is ~w~n",[self(), From]),
                    From ! {abort, self(), SeqNum},
                    io:format("Routing table of ~w is ~w~n",[self(), ets:tab2list(RoutingTable)]),
                    readyReceive(RouterName, RoutingTable, none, SeqNum);
                {control, From2, Pid, SeqNum2, ControlFun} ->
                    if 
                        SeqNum == SeqNum2 ->
                            true;
                        true ->
                            if
                                From2 == Pid ->
                                    From2 ! {abort, self(), SeqNum2};
                                true ->
                                    From2 ! {no, self(), SeqNum2}
                            end
                    end,
                    rootTwoPCCommitted(RouterName, RoutingTable, From, SeqNum, CommittedCount);
                {yes, From2, SeqNum} ->
                    rootTwoPCCommitted(RouterName, RoutingTable, From, SeqNum, CommittedCount);
                {no, From2, SeqNum} ->
                    rootTwoPCCommitted(RouterName, RoutingTable, From, SeqNum, CommittedCount);
                {doCommit, From2, SeqNum} ->
                    rootTwoPCCommitted(RouterName, RoutingTable, From, SeqNum, CommittedCount);
                {doAbort, From2, SeqNum} ->
                    %NumNeighbours = sendToNeighbours(OldTable, doAbort, SeqNum, 0), % propagate doCommit to all other nodes
                    From2 ! {abort, self(), SeqNum},
                    rootTwoPCCommitted(RouterName, RoutingTable, From, SeqNum, CommittedCount)
            end
    end.


sendControlToNeighbours([H|T], Pid, SeqNum, ControlFun, NumNeighbours) ->
    {Key, Dest} = H,
    if
        % Skip this entry in routing table
        Key == '$NoInEdges' ->
            sendControlToNeighbours(T, Pid, SeqNum, ControlFun, NumNeighbours);
        true ->
            Dest ! {control, self(), Pid, SeqNum, ControlFun},
            sendControlToNeighbours(T, Pid, SeqNum, ControlFun, NumNeighbours + 1)
    end;
sendControlToNeighbours([], Pid, SeqNum, ControlFun, NumNeighbours) ->
    NumNeighbours.

sendToNeighbours([H|T], Message, SeqNum, NumNeighbours) ->
    {Key, Dest} = H,
    if
        % Skip this entry in routing table
        Key == '$NoInEdges' ->
            sendToNeighbours(T, Message, SeqNum, NumNeighbours);
        true ->
            Dest ! {Message, self(), SeqNum},
            sendToNeighbours(T, Message, SeqNum, NumNeighbours + 1)
    end;
sendToNeighbours([], Message, SeqNum, NumNeighbours) ->
    NumNeighbours.

% recurse over children in the list [H|T] to kill all children
killChildren([H|T]) ->
    exit(H, kill),
    killChildren(T);
killChildren([]) ->
    true.
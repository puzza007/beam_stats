-module(beam_stats_msg_graphite).

-include("include/beam_stats.hrl").
-include("include/beam_stats_ets_table.hrl").
-include("include/beam_stats_msg_graphite.hrl").
-include("include/beam_stats_process.hrl").
-include("include/beam_stats_process_ancestry.hrl").
-include("include/beam_stats_processes.hrl").

-export_type(
    [ t/0
    ]).

-export(
    [ of_beam_stats/1
    %, to_bin/1
    ]).

-define(T, #?MODULE).

-type t() ::
    ?T{}.

-spec of_beam_stats(beam_stats:t()) ->
    [t()].
of_beam_stats(#beam_stats{node_id=NodeID}=BeamStats) ->
    NodeIDBin = node_id_to_bin(NodeID),
    of_beam_stats(BeamStats, NodeIDBin).

-spec of_beam_stats(beam_stats:t(), binary()) ->
    [t()].
of_beam_stats(#beam_stats
    { timestamp = Timestamp
    , node_id   = _
    , memory    = Memory
    % TODO: Handle the rest of data points
    , io_bytes_in      = IOBytesIn
    , io_bytes_out     = IOBytesOut
    , context_switches = ContextSwitches
    , reductions       = Reductions
    , run_queue        = RunQueue
    , ets              = ETS
    , processes        = Processes
    },
    <<NodeID/binary>>
) ->
    Ts = Timestamp,
    N = NodeID,
    [ cons([N, <<"io">>               , <<"bytes_in">> ], IOBytesIn      , Ts)
    , cons([N, <<"io">>               , <<"bytes_out">>], IOBytesOut     , Ts)
    , cons([N, <<"context_switches">>                  ], ContextSwitches, Ts)
    , cons([N, <<"reductions">>                        ], Reductions     , Ts)
    , cons([N, <<"run_queue">>                         ], RunQueue       , Ts)
    | of_memory(Memory, NodeID, Ts)
    ]
    ++ of_ets(ETS, NodeID, Ts)
    ++ of_processes(Processes, NodeID, Ts).

-spec of_memory([{atom(), non_neg_integer()}], binary(), erlang:timestamp()) ->
    [t()].
of_memory(Memory, <<NodeID/binary>>, Timestamp) ->
    ComponentToMessage =
        fun ({Key, Value}) ->
            KeyBin = atom_to_binary(Key, latin1),
            cons([NodeID, <<"memory">>, KeyBin], Value, Timestamp)
        end,
    lists:map(ComponentToMessage, Memory).

-spec of_ets(beam_stats_ets_table:t(), binary(), erlang:timestamp()) ->
    [t()].
of_ets(PerTableStats, <<NodeID/binary>>, Timestamp) ->
    OfEtsTable = fun (Table) -> of_ets_table(Table, NodeID, Timestamp) end,
    NestedMsgs = lists:map(OfEtsTable, PerTableStats),
    lists:append(NestedMsgs).

-spec of_ets_table(beam_stats_ets_table:t(), binary(), erlang:timestamp()) ->
    [t()].
of_ets_table(#beam_stats_ets_table
    { id     = ID
    , name   = Name
    , size   = Size
    , memory = Memory
    },
    <<NodeID/binary>>,
    Timestamp
) ->
    IDBin     = beam_stats_ets_table:id_to_bin(ID),
    NameBin   = atom_to_binary(Name, latin1),
    NameAndID = [NameBin, IDBin],
    [ cons([NodeID, <<"ets_table">>, <<"size">>   | NameAndID], Size  , Timestamp)
    , cons([NodeID, <<"ets_table">>, <<"memory">> | NameAndID], Memory, Timestamp)
    ].

-spec of_processes(beam_stats_processes:t(), binary(), erlang:timestamp()) ->
    [t()].
of_processes(
    #beam_stats_processes
    { individual_stats         = Processes
    , count_all                = CountAll
    , count_exiting            = CountExiting
    , count_garbage_collecting = CountGarbageCollecting
    , count_registered         = CountRegistered
    , count_runnable           = CountRunnable
    , count_running            = CountRunning
    , count_suspended          = CountSuspended
    , count_waiting            = CountWaiting
    },
    <<NodeID/binary>>,
    Timestamp
) ->
    OfProcess = fun (P) -> of_process(P, NodeID, Timestamp) end,
    PerProcessMsgsNested = lists:map(OfProcess, Processes),
    PerProcessMsgsFlattened = lists:append(PerProcessMsgsNested),
    Ts = Timestamp,
    N  = NodeID,
    [ cons([N, <<"processes_count_all">>               ], CountAll              , Ts)
    , cons([N, <<"processes_count_exiting">>           ], CountExiting          , Ts)
    , cons([N, <<"processes_count_garbage_collecting">>], CountGarbageCollecting, Ts)
    , cons([N, <<"processes_count_registered">>        ], CountRegistered       , Ts)
    , cons([N, <<"processes_count_runnable">>          ], CountRunnable         , Ts)
    , cons([N, <<"processes_count_running">>           ], CountRunning          , Ts)
    , cons([N, <<"processes_count_suspended">>         ], CountSuspended        , Ts)
    , cons([N, <<"processes_count_waiting">>           ], CountWaiting          , Ts)
    | PerProcessMsgsFlattened
    ].

-spec of_process(beam_stats_process:t(), binary(), erlang:timestamp()) ->
    [t()].
of_process(
    #beam_stats_process
    { pid               = Pid
    , memory            = Memory
    , total_heap_size   = TotalHeapSize
    , stack_size        = StackSize
    , message_queue_len = MsgQueueLen
    }=Process,
    <<NodeID/binary>>,
    Timestamp
) ->
    Origin = beam_stats_process:get_best_known_origin(Process),
    OriginBin = proc_origin_to_bin(Origin),
    PidBin = pid_to_bin(Pid),
    OriginAndPid = [OriginBin, PidBin],
    Ts = Timestamp,
    N  = NodeID,
    [ cons([N, <<"process_memory">>            , OriginAndPid], Memory        , Ts)
    , cons([N, <<"process_total_heap_size">>   , OriginAndPid], TotalHeapSize , Ts)
    , cons([N, <<"process_stack_size">>        , OriginAndPid], StackSize     , Ts)
    , cons([N, <<"process_message_queue_len">> , OriginAndPid], MsgQueueLen   , Ts)
    ].

-spec proc_origin_to_bin(beam_stats_process:best_known_origin()) ->
    binary().
proc_origin_to_bin({registered_name, Name}) ->
    atom_to_binary(Name, utf8);
proc_origin_to_bin({ancestry, Ancestry}) ->
    #beam_stats_process_ancestry
    { raw_initial_call  = InitCallRaw
    , otp_initial_call  = InitCallOTPOpt
    , otp_ancestors     = AncestorsOpt
    } = Ancestry,
    Blank             = <<"NONE">>,
    InitCallOTPBinOpt = hope_option:map(InitCallOTPOpt   , fun mfa_to_bin/1),
    InitCallOTPBin    = hope_option:get(InitCallOTPBinOpt, Blank),
    AncestorsBinOpt   = hope_option:map(AncestorsOpt     , fun ancestors_to_bin/1),
    AncestorsBin      = hope_option:get(AncestorsBinOpt  , Blank),
    InitCallRawBin    = mfa_to_bin(InitCallRaw),
    << InitCallRawBin/binary
     , "--"
     , InitCallOTPBin/binary
     , "--"
     , AncestorsBin/binary
    >>.

ancestors_to_bin([]) ->
    <<>>;
ancestors_to_bin([A | Ancestors]) ->
    ABin = ancestor_to_bin(A),
    case ancestors_to_bin(Ancestors)
    of  <<>> ->
            ABin
    ;   <<AncestorsBin/binary>> ->
            <<ABin/binary, "-", AncestorsBin/binary>>
    end.

ancestor_to_bin(A) when is_atom(A) ->
    atom_to_binary(A, utf8);
ancestor_to_bin(A) when is_pid(A) ->
    pid_to_bin(A).

pid_to_bin(Pid) ->
    PidList = erlang:pid_to_list(Pid),
    PidBin = re:replace(PidList, "[\.]", "_", [global, {return, binary}]),
             re:replace(PidBin , "[><]", "" , [global, {return, binary}]).

-spec mfa_to_bin(mfa()) ->
    binary().
mfa_to_bin({Module, Function, Arity}) ->
    ModuleBin   = atom_to_binary(Module  , utf8),
    FunctionBin = atom_to_binary(Function, utf8),
    ArityBin    = erlang:integer_to_binary(Arity),
    <<ModuleBin/binary, "-", FunctionBin/binary, "-", ArityBin/binary>>.

-spec cons([binary()], integer(), erlang:timestamp()) ->
    t().
cons(Path, Value, Timestamp) ->
    ?T
    { path      = Path
    , value     = Value
    , timestamp = Timestamp
    }.

-spec node_id_to_bin(node()) ->
    binary().
node_id_to_bin(NodeID) ->
    NodeIDBin = atom_to_binary(NodeID, utf8),
    re:replace(NodeIDBin, "[\@\.]", "_", [global, {return, binary}]).

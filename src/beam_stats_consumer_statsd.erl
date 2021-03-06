-module(beam_stats_consumer_statsd).

-include("include/beam_stats.hrl").
-include("beam_stats_logging.hrl").

-behaviour(beam_stats_consumer).

-export_type(
    [ option/0
    ]).

%% Consumer interface
-export(
    [ init/1
    , consume/2
    , terminate/1
    ]).

-type option() ::
      {consumption_interval , non_neg_integer()}
    | {dst_host             , inet:ip_address() | inet:hostname()}
    | {dst_port             , inet:port_number()}
    | {src_port             , inet:port_number()}
    | {num_msgs_per_packet  , non_neg_integer()}
    | {static_node_name     , binary()}
    .

-define(DEFAULT_DST_HOST, "localhost").
-define(DEFAULT_DST_PORT, 8125).
-define(DEFAULT_SRC_PORT, 8124).

-record(state,
    { sock     :: hope_option:t(gen_udp:socket())
    , dst_host :: inet:ip_address() | inet:hostname()
    , dst_port :: inet:port_number()
    , src_port :: inet:port_number()
    , num_msgs_per_packet :: non_neg_integer()
    , static_node_name    :: hope_option:t(binary())
    }).

-type state() ::
    #state{}.

%% ============================================================================
%% Consumer implementation
%% ============================================================================

-spec init([option()]) ->
    {non_neg_integer(), state()}.
init(Options) ->
    ConsumptionInterval = hope_kv_list:get(Options, consumption_interval, 60000),
    DstHost = hope_kv_list:get(Options, dst_host, ?DEFAULT_DST_HOST),
    DstPort = hope_kv_list:get(Options, dst_port, ?DEFAULT_DST_PORT),
    SrcPort = hope_kv_list:get(Options, src_port, ?DEFAULT_SRC_PORT),
    NumMsgsPerPacket = hope_kv_list:get(Options, num_msgs_per_packet, 10),
    StaticNodeNameOpt = hope_kv_list:get(Options, static_node_name),
    State = #state
        { sock     = none
        , dst_host = DstHost
        , dst_port = DstPort
        , src_port = SrcPort
        , num_msgs_per_packet = NumMsgsPerPacket
        , static_node_name    = StaticNodeNameOpt
        },
    {ConsumptionInterval, State}.

-spec consume(beam_stats_consumer:queue(), state()) ->
    state().
consume(
    Q,
    #state
    { num_msgs_per_packet = NumMsgsPerPacket
    , static_node_name    = StaticNodeNameOpt
    }=State
) ->
    Packets = beam_stats_queue_to_packets(Q, NumMsgsPerPacket, StaticNodeNameOpt),
    lists:foldl(fun try_to_connect_and_send/2, State, Packets).

-spec terminate(state()) ->
    {}.
terminate(#state{sock=SockOpt}) ->
    ok = hope_option:iter(SockOpt, fun gen_udp:close/1),
    {}.

%% ============================================================================
%% Transport
%% ============================================================================

-spec try_to_connect_and_send(iolist(), state()) ->
    state().
try_to_connect_and_send(Payload, #state{}=State1) ->
    State2 = try_to_connect_if_no_socket(State1),
    try_to_send(State2, Payload).

-spec try_to_send(state(), iolist()) ->
    state().
try_to_send(#state{sock=none}=State, _) ->
    ?log_error("Sending failed. No socket in state."),
    % TODO: Maybe schedule retry?
    State;
try_to_send(
    #state
    { sock     = {some, Sock}
    , dst_host = DstHost
    , dst_port = DstPort
    }=State,
    Payload
) ->
    case gen_udp:send(Sock, DstHost, DstPort, Payload)
    of  ok ->
            State
    ;   {error, _}=Error ->
            ?log_error(
                "gen_udp:send(~p, ~p, ~p, Payload) -> ~p",
                [Sock, DstHost, DstPort, Error]
            ),
            % TODO: Do something with unsent messages?
            ok = gen_udp:close(Sock),
            State#state{sock=none}
    end.

-spec try_to_connect_if_no_socket(state()) ->
    state().
try_to_connect_if_no_socket(#state{sock={some, _}}=State) ->
    State;
try_to_connect_if_no_socket(#state{sock=none, src_port=SrcPort}=State) ->
    case gen_udp:open(SrcPort)
    of  {ok, Sock} ->
            State#state{sock = {some, Sock}}
    ;   {error, _}=Error ->
            ?log_error("gen_udp:open(~p) -> ~p", [SrcPort, Error]),
            State#state{sock = none}
    end.

%% ============================================================================
%% Serialization
%% ============================================================================

-spec beam_stats_queue_to_packets(
    beam_stats_consumer:queue(),
    non_neg_integer(),
    hope_option:t(binary())
) ->
    [iolist()].
beam_stats_queue_to_packets(Q, NumMsgsPerPacket, StaticNodeNameOpt) ->
    MsgIOLists = lists:append([beam_stats_to_iolists(B, StaticNodeNameOpt) || B <- queue:to_list(Q)]),
    hope_list:divide(MsgIOLists, NumMsgsPerPacket).

-spec beam_stats_to_iolists(beam_stats:t(), hope_option:t(binary())) ->
    [iolist()].
beam_stats_to_iolists(#beam_stats{node_id=NodeID}=BeamStats, StaticNodeNameOpt) ->
    NodeIDBinDefault = beam_stats_msg_graphite:node_id_to_bin(NodeID),
    NodeIDBin = hope_option:get(StaticNodeNameOpt, NodeIDBinDefault),
    MsgsGraphite = beam_stats_msg_graphite:of_beam_stats(BeamStats, NodeIDBin),
    MsgsStatsD =
        lists:map(fun beam_stats_msg_statsd_gauge:of_msg_graphite/1, MsgsGraphite),
    lists:map(fun beam_stats_msg_statsd_gauge:to_iolist/1, MsgsStatsD).

-module(eadc_client_fsm).
-author('jlarky@gmail.com').

-behaviour(gen_fsm).

-export([start_link/0, set_socket/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3,
         handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

%% FSM States
-export([
	 'WAIT_FOR_SOCKET'/2,
	 'IDENTIFY STAGE'/2,
	 'PROTOCOL STAGE'/2,
	 'NORMAL STAGE'/2
	]).

-record(state, {
	  socket,    % client socket
	  addr,      % client address
	  sid,       % client's SID
	  binf,      % bif string to send to other clients
	  buf        % buffer for client messages sended in several tcp pockets
	 }).

%% HELPING FUNCTIONS
-export([all_pids/0]).

%% DEBUG
-export([test/1, get_sid_by_pid/1]).

-define(TIMEOUT, 120000).
-include("eadc.hrl").

%%%------------------------------------------------------------------------
%%% API
%%%------------------------------------------------------------------------

%%-------------------------------------------------------------------------
%% @spec (Socket) -> {ok,Pid} | ignore | {error,Error}
%% @doc To be called by the supervisor in order to start the server.
%%      If init/1 fails with Reason, the function returns {error,Reason}.
%%      If init/1 returns {stop,Reason} or ignore, the process is
%%      terminated and the function returns {error,Reason} or ignore,
%%      respectively.
%% @end
%%-------------------------------------------------------------------------
start_link() ->
    gen_fsm:start_link(?MODULE, [], []).

set_socket(Pid, Socket) when is_pid(Pid), is_port(Socket) ->
    gen_fsm:send_event(Pid, {socket_ready, Socket}).

%%%------------------------------------------------------------------------
%%% Callback functions from gen_server
%%%------------------------------------------------------------------------

%%-------------------------------------------------------------------------
%% Func: init/1
%% Returns: {ok, StateName, StateData}          |
%%          {ok, StateName, StateData, Timeout} |
%%          ignore                              |
%%          {stop, StopReason}
%% @private
%%-------------------------------------------------------------------------
init([]) ->
    process_flag(trap_exit, true),
    {ok, 'WAIT_FOR_SOCKET', #state{buf=[]}}.

%%-------------------------------------------------------------------------
%% Func: StateName/2
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%% @private
%%-------------------------------------------------------------------------
'WAIT_FOR_SOCKET'({socket_ready, Socket}, State) when is_port(Socket) ->
    %% Now we own the socket
    error_logger:info_msg("new socket ~w\n", [{Socket, ok}]),

    inet:setopts(Socket, [{active, once}, {packet, line}]),
    {ok, {IP, _Port}} = inet:peername(Socket),
    {next_state, 'PROTOCOL STAGE', State#state{socket=Socket, addr=IP}, ?TIMEOUT};
'WAIT_FOR_SOCKET'(Other, State) ->
    error_logger:error_msg("State: 'WAIT_FOR_SOCKET'. Unexpected message: ~p\n", [Other]),
    %% Allow to receive async messages
    {next_state, 'WAIT_FOR_SOCKET', State}.

'PROTOCOL STAGE'({data, Data}, #state{socket=Socket} = State) ->
    ?DEBUG(debug, "Data recived ~w~n", [Data]),
    case Data of
	[ $H,$S,$U,$P,$\  | _] ->
	    {A,B,C}=time(), random:seed(A,B,C),
	    ok = gen_tcp:send(Socket, "ISUP ADBASE ADTIGR\n"),
	    Sid = get_unical_SID(),
	    ok = gen_tcp:send(Socket, "ISID "++Sid ++"\n"),
	    {next_state, 'IDENTIFY STAGE', State, ?TIMEOUT};
	_ ->
	    ok = gen_tcp:send(Socket, "ISTA 240 Protocol error\n"),
	    {next_state, 'PROTOCOL STAGE', State, ?TIMEOUT}
    end;

'PROTOCOL STAGE'(timeout,  #state{socket=Socket} = State) ->
    ok = gen_tcp:send(Socket, "Protocol Error: connection timed out\n"),
    error_logger:info_msg("Client '~w' timed out\n", [self()]),
    {stop, normal, State}.

'IDENTIFY STAGE'({data, Data}, #state{socket=Socket, addr=Addr}=State) ->
    ?DEBUG(debug, "String recived '~s'~n", [Data]),
    {list, List} = eadc_utils:convert({string, Data}),
    case List of
	["BINF", SID | _] ->
	    ?DEBUG(debug, "New client with BINF= '~s'~n", [Data]),
	    My_Pid=self(), Sid = list_to_atom(SID),
	    {I1,I2,I3,I4} = Addr,
	    Inf=inf_update(Data, [lists:concat(["I4",I1,".",I2,".",I3,".",I4])]),
	    New_State=State#state{binf=Inf, sid=Sid},
	    Other_clients = all_pids(), %% важно, что перед операцией записи
	    ets:insert(eadc_clients, #client{pid=My_Pid, sid=Sid}),
	    case eadc_plugin:hook(user_login, [{sid,SID},{pid,My_Pid},
					      {inf, Inf}]) of
		true ->
		    plugin_interupt;
		false ->
		    lists:foreach(fun(Pid) ->
					  gen_fsm:send_event(Pid, {new_client, My_Pid})
				  end, Other_clients),
		    lists:foreach(fun(Pid) ->
					  gen_fsm:send_event(Pid, {send_to_socket, Inf})
				  end, [self()|Other_clients])
	    end,		    
	    %% gen_fsm:send_event(My_Pid, {send_to_socket, "IGPA A\n"}),
	    {next_state, 'NORMAL STAGE', New_State, ?TIMEOUT};
	_ ->
	    ok = gen_tcp:send(Socket, "ISTA 240 Protocol error\n"),
	    {next_state, 'IDENTIFY STAGE', State, ?TIMEOUT}
    end;

'IDENTIFY STAGE'(timeout,  #state{socket=Socket} = State) ->
    ok = gen_tcp:send(Socket, "Protocol Error: connection timed out\n"),
    error_logger:info_msg("Client '~w' timed out\n", [self()]),
    {stop, normal, State}.


'NORMAL STAGE'({data, Data}, #state{socket=Socket} = State) ->
    ?DEBUG(debug, "DATA recived '~s'~n", [Data]),
    {list, List}=eadc_utils:convert({string, Data}),
    case List of
	[[Header|Command_name]|Tail] ->
	    catch client_command(list_to_atom([Header]), list_to_atom(Command_name), Tail),
	    ?DEBUG(debug, "Command recived '~s'~n", [Data]);
	_ ->
	    ok = gen_tcp:send(Socket, "ISTA 240 Protocol error\n")
    end,
    {next_state, 'NORMAL STAGE', State};

'NORMAL STAGE'({inf_update, Inf_update}, #state{binf=Inf} = State) ->
    ?DEBUG(debug, "BINF Update '~w'~n", [Inf_update]),
    ?DEBUG(debug, "Old BINF '~s'~n", [Inf]),
    New_Inf=inf_update(Inf, Inf_update),
    ?DEBUG(debug, "New BINF '~s'~n", [New_Inf]),
    {next_state, 'NORMAL STAGE', State#state{binf=New_Inf}};

'NORMAL STAGE'({new_client, Pid}, #state{binf=BINF} = State) ->
    ?DEBUG(debug, "new_client event from ~w \n", [Pid]),
    gen_fsm:send_event(Pid, {send_to_socket, BINF}),
    {next_state, 'NORMAL STAGE', State};

'NORMAL STAGE'({send_to_socket, Data}, #state{socket=Socket} = State) ->
    ?DEBUG(debug, "send_to_socket event '~s'~n", [Data]),
    ok = gen_tcp:send(Socket, lists:concat([Data, "\n"])),
    {next_state, 'NORMAL STAGE', State};

'NORMAL STAGE'(Other, State) ->
    ?DEBUG(debug, "Unknown message '~s' ~n", [Other]),
    {next_state, 'NORMAL STAGE', State}.


%%-------------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%% @private
%%-------------------------------------------------------------------------
handle_event(Event, StateName, StateData) ->
    {stop, {StateName, undefined_event, Event}, StateData}.

%%-------------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%% @private
%%-------------------------------------------------------------------------
handle_sync_event(Event, _From, StateName, StateData) ->
    {stop, {StateName, undefined_event, Event}, StateData}.

%%-------------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%% @private
%%-------------------------------------------------------------------------
handle_info({tcp, Socket, Bin}, StateName, #state{socket=Socket, buf=Buf} = StateData) ->
    %% Flow control: enable forwarding of next TCP message
    inet:setopts(Socket, [{active, once}]),
    Data = binary_to_list(Bin),
    String = lists:delete($\n, Data),
    ?DEBUG(debug, "", String), 
    case {Buf, lists:last(Data)} of 
	{[], 10} -> 
	    ?MODULE:StateName({data, String}, StateData);
	{_, 10} ->
	    ?MODULE:StateName({data, lists:concat([Buf,Data])}, StateData#state{buf=[]});
	_ -> 
	    {next_state, StateName, StateData#state{buf=lists:concat([Buf,Data])}}
    end;


handle_info({tcp_closed, Socket}, _StateName,
            #state{socket=Socket, addr=Addr} = StateData) ->
    error_logger:info_msg("~p Client ~p disconnected.\n", [self(), Addr]),
    {stop, normal, StateData};

handle_info({master, Data}, StateName, StateData) ->
    ?MODULE:StateName({master, Data}, StateData);

handle_info(_Info, StateName, StateData) ->
    {noreply, StateName, StateData}.


%%-------------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%% @private
%%-------------------------------------------------------------------------
terminate(_Reason, _StateName, #state{socket=Socket, sid=Sid}) ->
    ?DEBUG(debug, "TERMINATE ~w", [Sid]),
    (catch ets:delete(eadc_clients, Sid)),
    String_to_send = "IQUI "++ atom_to_list(Sid) ++"\n",
    lists:foreach(fun(Pid) ->
			  gen_fsm:send_event(Pid, {send_to_socket, String_to_send})
		  end, all_pids()),
    (catch gen_tcp:send(Socket, String_to_send)),
    (catch gen_tcp:close(Socket)),
    ok.

%%-------------------------------------------------------------------------
%% Func: code_change/4
%% Purpose: Convert process state when code is changed
%% Returns: {ok, NewState, NewStateData}
%% @private
%%-------------------------------------------------------------------------
code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.


%%%------------------------------------------------------------------------
%%% Internal functions
%%%------------------------------------------------------------------------

client_command(Header, Command, Args) ->
    {string, String}=eadc_utils:convert({list, Args}),
    String_to_send=lists:concat([Header, Command, " ", String]),
    Pids = case {Header,Command} of 
	       {'B','MSG'} ->
		   [Sid, Msg] = Args,
		   case eadc_plugin:hook(chat_msg, [{pid, self()}, {msg, Msg},{sid,Sid}]) of
		       true -> [];
		       false -> all_pids()
		   end;
	       {'E', 'MSG'} ->
		   [Sid1, Sid2 | _] = Args, [get_pid_by_sid(Sid1), get_pid_by_sid(Sid2)];
	       {'D', 'RCM'} ->
		   [_Sid1, Sid2 | _] = Args, [get_pid_by_sid(Sid2)];
	       {'D', 'CTM'} ->
		   [_Sid1, Sid2 | _] = Args, [get_pid_by_sid(Sid2)];
	       {'B', 'INF'} ->
		   [_sid | Filds] = Args,
		   gen_fsm:send_event(self(), {inf_update, Filds}),
		   all_pids();
	       {'B', 'SCH'} ->
		   all_pids();
	       {'F', 'SCH'} ->
		   all_pids(); %% надо бы искать по признаку поддержки фичи
	       {'D', 'RES'} ->
		   [_Sid1, Sid2 | _] = Args, [get_pid_by_sid(Sid2)];
	       {place, holder} ->
		   ok
	   end,
    lists:foreach(fun(Pid) ->
			  gen_fsm:send_event(Pid, {send_to_socket, String_to_send})
		  end, Pids).




%%%------------------------------------------------------------------------                                                                                            
%%% Helping functions                                                                                            
%%%------------------------------------------------------------------------

get_unical_SID() ->
    Sid = eadc_utils:random_base32(4),
    case ets:member(eadc_clients, list_to_atom(Sid)) of
	true -> get_unical_SID();
	_    -> Sid
    end.

get_pid_by_sid(Sid) when is_atom(Sid) ->
    case ets:lookup(eadc_clients, Sid) of
	[] ->
	    error;
	[Client] ->
	    Client#client.pid
    end;
get_pid_by_sid(Sid) when is_list(Sid)->
    get_pid_by_sid(list_to_atom(Sid)).


get_sid_by_pid(Pid) when is_pid(Pid) ->
    MS=[{{client, '$1','$2'},[{'==','$2',Pid}],['$1']}],
    case ets:select(eadc_clients, MS) of
	[] -> error;
	[Sid] -> Sid
    end.

all_pids() ->
    List=ets:match(eadc_clients, #client{_='_', pid='$1'}),
    lists:map(fun([Pid]) -> Pid end, List).


test(String) ->
    [Pid | _] =all_pids(),
    gen_fsm:send_event(Pid, {send_to_socket, String}).



inf_update(Inf, Inf_update) ->
    {list, [_binf, Sid | Inf_list]} = eadc_utils:convert({string, Inf}),
    New_Inf_list=
	lists:foldl(
	  fun(Cur_Inf_Elem, Inf_Acc) ->
		  Updated_Inf_Elem = 
		      lists:foldl(
			fun(Cur_Upd_Elem, Inf_Elem_Acc) -> 
				case lists:prefix(lists:sublist(Cur_Upd_Elem, 2), Inf_Elem_Acc) of
				    true -> Cur_Upd_Elem;
				    false -> Inf_Elem_Acc
				end
			end, Cur_Inf_Elem, Inf_update),
		  [Updated_Inf_Elem|Inf_Acc]
	  end, [], lists:reverse(Inf_list)),
    {string, New_Inf} = eadc_utils:convert({list, ["BINF", Sid | New_Inf_list]}),
    New_Inf.


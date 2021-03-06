%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% eadc-hub - ADC hub software written using Erlang/OTP.
%%% Copyright (c) 2010, JLarky <jlarky@gmail.com>
%%%
%%% This program is free software; you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation; either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program.  If not, see <http://www.gnu.org/licenses/>.
%%%

%%%-------------------------------------------------------------------
%%% File    : eadc_client.erl
%%% Author  : airelain <airelain@eeepc>
%%% Description : 
%%%
%%% Created :  2 Apr 2010 by airelain <airelain@eeepc>
%%%-------------------------------------------------------------------
-module(eadc_client).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([logoff/2]).
-export([client_get/1,client_all/0,client_write/1,client_delete/1]).

%% profile
-export([profile_start/0, profile_stop/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

%% spawn calls
%-export([user_login_/1]).

-define(TIMEOUT, 30000).
-include("eadc.hrl").

-export([get_socket_by_sid/1,all_senders/0]).
-export([get_uniq_sid/0, get_uniq_cid/0, get_uniq_cid/1]).


%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, eadc_client}, ?MODULE, [], []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    %%eadc_connect_state:start_link(),
    eadc_app:start_table(client, [{attributes,
				   record_info(fields, client)},
				  {disc_copies, [node()]}], [{clear, true}]),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    error_logger:info_msg("unhandled call ~p\n",[_Request]),
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({accept,Sender},State) ->
    connect_set(#connect{sender=Sender,statename=wait_data}),
    {noreply,State};
handle_cast({received,Sender,Data},State) ->
    case connect_get(Sender) of
	{hz, HZ} -> 
	    %% каким-то волшебным образом мы получили данные из сокета,
	    %% который не прислал accept, лучше нафиг его послать
	    ?DEBUG(error, "HZ received ~p,~p:\n~p",[{received,Sender,Data},State,HZ]),
	    catch sockroute:close(Sender);
	{ok, Connect} ->
	    handle_received(Connect,Data)
    end,
    {noreply,State};
handle_cast({closed,Sender}, State) ->
    case catch connect_get(Sender) of
	{ok,Connect} when is_record(Connect,connect) ->
	    logoff(Connect,"");
	{hz,[]} ->
	    not_in_connect;
	Error ->
	    ?DEBUG(error, "error in handle_cast({closed, ~p}, ~p)\n~p", [Sender,State,Error])
    end,
    {noreply,State};
handle_cast(_Msg, State) ->
    error_logger:info_msg("unhandled cast ~p\n",[_Msg]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    error_logger:info_msg("unhandled info ~p\n",[_Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    error_logger:info_msg("terminate ~p\n",[{_Reason,ets:info(connect_states)}]),
    Kill=fun(C) -> logoff(C,"Something goes really wrong") end,
    catch lists:foreach(Kill,connect_all()),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

handle_received(Connect,Data) ->
    handle_received(Data, Connect#connect.buff, Connect).

handle_received([], Buff, #connect{buff=Buff}) ->
    %% no need to save
    ok;
handle_received([], Buff, Connect) ->
    %% save buffer
    connect_set(Connect#connect{buff=Buff}),
    ok;
handle_received([$\n|Tail], Buff, Connect) ->
    handle_data(Connect, lists:reverse(Buff)),
    handle_received(Tail, [], Connect);
handle_received([H|Tail], Buff, Connect) ->
    handle_received(Tail, [H|Buff], Connect).


handle_data(Connect,"") -> %% keep alive
    sockroute:asend(Connect#connect.sender,"\n");
handle_data(Connect,Data) ->
    Message=string:tokens(Data, " "),
    case Message of
	[[Header|Command_name]|Tail] ->
	    H = [Header],Cmd=Command_name,
	    case (catch handle_command(H,Cmd,Tail,Data,Connect)) of
		ok ->
		    ok;
		Error ->
		    ?ERROR("Error in handle data: ~p\n",[Error]),
		    ok
	    end
    end.

%% суть хаба по хедеру понять где взять цели куда нужно
%% посылать сообщение, лишь иногда хабу нужно как-то менять
%% посылаемое сообещение или не посылать его вовсе

%% в итоге: берём хедер, получаем список получаетелей и шлём.
handle_command(H, Cmd, Tail, Data, Connect) ->
    StateName=Connect#connect.statename,
    case catch handle_command(H, Cmd, Tail, Data, Connect, StateName) of
	{Senders2send, Data2send} when is_list(Senders2send) ->
	    ?DEBUG(info, "command handled ~ts\n",[Data2send]),
	    case catch eadc_utils:send_to_senders(Senders2send,Data2send) of
		ok -> ok;
		Error ->
		    ?DEBUG(error, "Error in handle command ~p: ~p\n",
			   [{H, Cmd, Tail, Data, Connect},Error])
	    end;
	{setconnect, NewConnect} ->
	    connect_set(NewConnect);
	{stop, Client, Msg} ->
	    logoff(Client, Msg);
	Other when StateName=/=normal-> %% like critical error? ->
	    error_logger:format("Error in handle_command ~p:\n ~p", [{H, Cmd, Tail, Data, Connect},Other]),
	    logoff(Connect, eadc_utils:format("Critical error in ~p\n",[{H, Cmd}]));
	Other ->
	    error_logger:format("Other ~p: ~p", [{H, Cmd, Tail, Data, Connect},Other])
    end,
    ok.

handle_command(H, Cmd, Tail, Data, Connect, StateName) ->
    Client=get_client_by_sender(Connect#connect.sender),
    {Senders, Args} = %% в данном случае мы получаем список получателей
	case H of  %% и параметры для обработчика одним махом =)
	    "B" ->
		[MySid | Par] = Tail,
		{all_senders(),
		 [{par, Par}, {my_sid, MySid}]};
	    "I" ->
		{[], 
		 [{par, Tail}]};
	    "H" ->
		{[], 
		 [{par, Tail}]};
	    "D" ->
		[MySid, TSid | Par] = Tail, 
		{[get_socket_by_sid(TSid)], 
		 [{par, Par}, {my_sid, MySid}, {tar_sid, TSid}]};
	    "E" ->
		[MySid, TSid | Par] = Tail, 
		{[get_socket_by_sid(MySid), get_socket_by_sid(TSid)], 
		 [{par, Par}, {my_sid, MySid}, {tar_sid, TSid}]};
	    "F" ->
		[MySid | Par] = Tail,
		{sender_all(),
		 [{par, Par}, {my_sid, MySid}]}
	end,
    check_sid(Connect,eadc_utils:get_val(my_sid,Args),StateName),
    client_command(StateName,H,Cmd,Senders,Data,[{client,Client},{connect,Connect}|Args]).

%% WAIT DATA

client_command(wait_data,"H","SUP",[],_Data,Args) ->
    Connect=eadc_utils:get_val(connect,Args),
    Sender=Connect#connect.sender,
    SupList=eadc_utils:get_val(par,Args),
    Sup=sup_update([], SupList),
    sockroute:asend(Sender,"ISUP ADBAS0 ADBASE ADTIGR ADUCM0 ADUCMD\n"),
    Sid=get_uniq_sid(),
    SID=eadc_utils:sid_to_s(Sid),
    sockroute:asend(Sender,cat(["ISID ",SID,"\n"])),
    case inet:peername(Sender#sender.socket) of
	{ok, {IP, _Port}} ->
	    Client=#client{sid=Sid,sender=Sender,addr=IP,sup=Sup,other=[]},
	    NewConnect=Connect#connect{statename=wait_inf,adcsid=Sid,pre_client=Client},
	    {setconnect,NewConnect};
	_Error ->
	    {stop, Connect#connect{adcsid=Sid}, "socket dead"}
    end;

%% WAIT INF

client_command(wait_inf,"B","INF",_Senders,Data,Args_) ->
    Connect=eadc_utils:get_val(connect,Args_),
    Client=Connect#connect.pre_client,
    Addr=Client#client.addr,
    ?DEBUG(debug, "New client with BINF= '~s'~n", [Data]),
    ?DEBUG(error, "New client '~w'~n", [Addr]),

    eadc_utils:send_to_client(Client,"IINF CT32 VEEADC NIADCHub DE\n"),

    P_Inf=eadc_utils:parse_inf(Data),

    Nick=eadc_utils:get_nick_field(P_Inf),
    Cid=eadc_utils:get_cid_field(P_Inf,Client#client{nick=Nick}),

    {I1,I2,I3,I4} = Addr,
    Inf=inf_update(Data, [lists:concat(["I4",I1,".",I2,".",I3,".",I4]),
			  "PD","ID"++Cid, "NI"++Nick]),
    
    Login=eadc_user:account_get_login(Nick, Cid),
    
    New_Client=Client#client{%%sid,sender,sup,addr,other --- already set
		 pid=self(),cid=Cid,nick=Nick,login=Login,inf=Inf},

    case need_authority(Nick, Cid) of
	true ->
	    Random=tiger:hash(eadc_utils:random_string(24)),
	    eadc_utils:send_to_client(Client,{args,["IGPA", eadc_utils:base32_encode(Random)]}),
	    NNClient=New_Client#client{other=[{random,Random},{triesleft,3},{login,Login}]},
	    {setconnect, Connect#connect{statename=wait_pass,pre_client=NNClient}};
	false ->
	    user_login(New_Client),%%free pre_client, beacause user_login saved it in client base
	    {setconnect, Connect#connect{statename=normal,pre_client=undefined}}
    end;

%% WAIT PASS

client_command(wait_pass, "H", "PAS", [], _Data, Args) ->
    Connect=eadc_utils:get_val(connect,Args),
    Client=Connect#connect.pre_client,
    #client{other=Other,addr=Addr,cid=Cid}=Client,
    Random=eadc_utils:get_val(random,Other),
    Tries_left=eadc_utils:get_val(triesleft,Other),
    Login=eadc_utils:get_val(login,Other),
    Account=eadc_user:account_get(Login),

    case eadc_utils:get_val(par,Args) of
	[_Pass] -> Pass=_Pass;
	_ ->Pass=return({[Connect#connect.sender],eadc_utils:a2s(["ISTA", "100", "wait for PAS"])})
    end,
    CID=list_val(catch eadc_utils:base32_decode(Cid)),
    User_Pass=list_val(Account#account.pass),

    N_P=User_Pass++Random,        %% 0.7
    C_N_P=CID++User_Pass++Random, %% draft
    H_N_P=(catch eadc_utils:base32_encode(tiger:hash(N_P))),
    H_C_N_P=(catch eadc_utils:base32_encode(tiger:hash(C_N_P))),
    ?DEBUG(debug, "DATA recived in VERIFY pass for ~s(~p) '~p'~n", 
	   [Login,Addr,{Pass,H_N_P,H_C_N_P}]),
    case Pass of
	P when (P==H_N_P) or (P==H_C_N_P) -> % pass correct
	    case lists:member(root,Account#account.roles) of
		true ->  Inf_update=["CT4"];
		false -> Inf_update=["CT2"]
	    end,
	    New_Inf_full=inf_update(Client#client.inf, Inf_update),
	    user_login(Client#client{inf=New_Inf_full,login=Login,other=[]}),
	    return({setconnect,Connect#connect{pre_client=undefined,statename=normal}});
	_ -> % pass wrong
	    below
    end,
    case (catch Tries_left-1) of
	I when is_integer(I) and (I > 0) ->
	    eadc_utils:send_to_client(Client,{args,["ISTA","123","Wrong password"]}),
	    timer:sleep(1000),New_Random=tiger:hash(eadc_utils:random_string(24)),
	    eadc_utils:send_to_client(Client,{args,["IGPA",eadc_utils:base32_encode(New_Random)]}),
	    Other1=eadc_utils:set_val(random,New_Random,Other),
	    Other2=eadc_utils:set_val(triesleft,I,Other1),
	    NewClient=(Connect#connect.pre_client)#client{other=Other2},
	    {setconnect,Connect#connect{pre_client=NewClient}};
	_Other ->
	    %% TODO: send message to user
	    logoff(Client,{string, eadc_utils:a2s(["ISTA","123","Wrong password"])})
    end;

%% NORMAL

client_command(_StateName=normal,"B","INF",Senders,Data,Args) ->
    Client=eadc_utils:get_val(client,Args),
    %% user not allow to change his CT or ID or share PD
    Inf_update=lists:filter(fun(A) -> not (lists:prefix("CT", A) or
					   lists:prefix("ID", A) or
					   lists:prefix("PD", A))
			    end, eadc_utils:get_val(par, Args)),
    New_Inf_full=inf_update(Client#client.inf, Inf_update),
    %% check nick
    P_Inf=eadc_utils:parse_inf(Data),
    Nick=eadc_utils:get_val('NI', Client#client.nick, P_Inf),

    client_write(Client#client{inf=New_Inf_full,nick=Nick}),
    New_Inf_to_send=inf_update(lists:sublist(New_Inf_full, 9), Inf_update),
    %% no any plugin
    {Senders,New_Inf_to_send};

client_command(_StateName=normal,"B","MSG",Senders,Data,Args) ->
    [Msg|_]=eadc_utils:get_val(par,Args),
    run_hook(chat_msg,Senders,Data,[{msg,eadc_utils:unquote(Msg)}|Args]);
client_command(_StateName=normal,"E","MSG",Senders,Data,Args) ->
    [Msg|_]=eadc_utils:get_val(par,Args),
    run_hook(priv_msg,Senders,Data,[{msg,eadc_utils:unquote(Msg)}|Args]);
client_command(_StateName=normal,"D","CTM",Senders,Data,Args) ->
    run_hook(ctm,Senders,Data,Args);
client_command(_StateName=normal,"D","RCM",Senders,Data,Args) ->
    run_hook(rcm,Senders,Data,Args);
client_command(_StateName=normal, _H,"SCH",Senders,Data,Args) ->
    run_hook(sch,Senders,Data,Args);
client_command(_StateName=normal, _H, _Cmd,Senders,Data,_Args) ->
    {Senders,Data}; %% no plugin

%% ERROR

client_command(StateName,Header,Command,Senders,Data,Args) ->
    error_logger:info_msg("unhandled command ~p\n",
			  [{StateName,Header,Command,Senders,Data,Args}]).


%%--------------------------------------------------------------------
%%% Helping functions
%%--------------------------------------------------------------------

sender_all() ->
    all_senders().

all_senders() ->
    MatchHead = #client{sender='$1', _='_'},Guard = [],Result = '$1',
    F = fun() ->
                mnesia:select(client,[{MatchHead, Guard, [Result]}])
        end,
    case catch mnesia:transaction(F) of
        {atomic, Senders} -> Senders;
        _Error -> []
    end.

get_socket_by_sid(Sid) when is_integer(Sid) ->
    MatchHead = #client{sid='$1', sender='$2', _='_'},
    Guard = [{'==', '$1', Sid}],
    Result = '$2',
        F = fun() ->
		    mnesia:select(client,[{MatchHead, Guard, [Result]}])
	    end,
    case catch mnesia:transaction(F) of
        {atomic, [Socket]} ->
	    %% list must contain one pid
	    Socket;
	Error -> {error, Error}
    end;


get_socket_by_sid(Sid) when is_list(Sid)->
    get_socket_by_sid(eadc_utils:unbase32(Sid)).


get_client_by_sender(Sender) when is_record(Sender,sender) ->
    case catch eadc_user:client_find(#client{sender=Sender,_='_'}) of
	[Client] ->
	    Client;
	[] ->
	    [];
	_Er ->
	    error_logger:format("error ~p\n",[_Er]),
	    []
    end.

sup_update(Sup, [[$A,$D| SupName]|Tail]) ->
    NotNew=fun(CSup) -> (CSup /= SupName) end,
    sup_update([SupName|lists:filter(NotNew, Sup)], Tail);
sup_update(Sup, [[$R,$M| SupName]|Tail]) when is_list(Sup) ->
    sup_update(lists:delete(SupName, Sup), Tail);
sup_update(Sup, [[_HZ_]|Tail]) ->
    sup_update(Sup, Tail);
sup_update(Sup, [_HZ_]) ->
    sup_update(Sup, []);
sup_update(Sup, []) ->
    Sup.


cat(A) when is_list(A) ->
    lists:concat(A).

get_uniq_cid() ->
    Cid=eadc_utils:random((1 bsl 192)-1),
     %% 192 bit
    get_uniq_cid(eadc_utils:cid_to_s(Cid)).

get_uniq_cid(Cid) ->
    MatchHead = #client{cid='$1', _='_'},Guard = [{'==', '$1', Cid}],Result = '$1',
    F = fun() ->
		mnesia:select(client,[{MatchHead, Guard, [Result]}])	
	end,
    case catch mnesia:transaction(F) of
	{atomic, []} -> %% not used CID
	    Cid;
	{atomic, [_|_]} -> %% CID allready in use, generate new
	    get_uniq_cid("CIDINUSE"++lists:sublist(eadc_utils:cid_to_s(eadc_utils:random((1 bsl 192)-1)) ,31));
	Error -> {error, Error} 
    end.

get_uniq_sid() ->
    Sid=eadc_utils:random(1048575), %% 20 bit and > 0 so can't be AAAA which reserved
    MatchHead = #client{sid='$1', _='_'},Guard = [{'==', '$1', Sid}],Result = '$1',
    F = fun() ->
		mnesia:select(client,[{MatchHead, Guard, [Result]}])	
	end,
    case catch mnesia:transaction(F) of
	{atomic, []} -> %% not used SID
	    Sid;
	{atomic, [_|_]} -> %% SID is allready in use, generate new
	    get_uniq_sid();
	Error -> {error, Error} 
    end.



list_val(Thing) when is_list(Thing) -> Thing;
list_val(_) -> "".


logoff(Client, Msg) when is_record(Client, client) ->
    #client{sender=Sender,sid=Sid}=Client,
    logoff(Sender, Sid, Msg);
logoff(Connect, Msg) when is_record(Connect,connect) ->
    #connect{sender=Sender,adcsid=Sid}=Connect,
    logoff(Sender,Sid,Msg).

logoff(Sender,Sid,"")->
    catch eadc_utils:broadcast({string,eadc_utils:a2s(["IQUI",eadc_utils:sid_to_s(Sid)])}),
    catch client_delete(Sid),
    catch connect_delete(Sender),
    catch sockroute:close(Sender),
    ok;
logoff(Sender,Sid,{string,Msg})->
    catch eadc_utils:send_to_sender(Sender, Msg),
    logoff(Sender,Sid,"");
logoff(Sender,Sid,Msg)->
    catch eadc_utils:info_to_sender(Sender, Msg),
    logoff(Sender,Sid,"").



need_authority(Nick, Cid) ->
    MatchHead = #account{cid='$1', nick='$2', _='_'},
    Guard = [{'or',{'==','$2',Nick},{'==','$1',Cid}}], Result = '$2',
    F = fun() ->
		mnesia:select(account,[{MatchHead, Guard, [Result]}])
	end,
    A=(catch mnesia:transaction(F)),
    case A of
	{atomic, [_|_]} -> %% not used SID
	    true;
	_ ->
	    false
    end.

get_val(A,B) ->
    eadc_utils:get_val(A,B).

return(A) ->
    throw(A).

%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% client functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%

client_get(Sid) ->
    F = fun()->
		mnesia:match_object(#client{sid=Sid,_='_'})
	end,

    case (catch mnesia:transaction(F)) of
	{atomic, [Client]} ->
	    Client#client{};
	_ ->
	    undefined
    end.

client_write(Client) when is_record(Client, client)->
    F=fun() ->
	      mnesia:write(Client)
      end,
    mnesia:transaction(F).


client_delete(Sid) ->
    mnesia:transaction(fun() ->
			       mnesia:delete({client, Sid})
		       end).

client_all() ->
    F = fun()->
		mnesia:match_object(#client{_='_'})
	end,

    case (catch mnesia:transaction(F)) of
	{atomic, Clients} when is_list(Clients) ->
	    Clients;
	_ ->
	    {undefined, ?FILE, ?LINE}
    end.




thing_to_string(Thing) ->
    lists:flatten(io_lib:format("~p",[Thing])).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% connect functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

connect_get(Sender) ->
    gen_server:call(eadc_connect_state, {get, Sender}).

connect_all() ->
    gen_server:call(eadc_connect_state, {getall}).

connect_set(Connect) ->
    gen_server:call(eadc_connect_state, {insert, Connect}).

connect_delete(Sender) ->
    gen_server:call(eadc_connect_state, {delete, Sender}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

inf_update_cur(Update, [], Acc) ->
    [Update|Acc];            %% adds new field
inf_update_cur([A1,A2], [[A1,A2|_Val]|Tail], Acc) ->
    Tail++Acc;               %% deletes empthy field
inf_update_cur([A1,A2|Val], [[A1,A2|_Val]|Tail], Acc) ->
    [[A1,A2|Val]|Tail++Acc]; %% change field value
inf_update_cur(Cur_Update, [Cur_Inf|Tail], Acc) ->
    inf_update_cur(Cur_Update, Tail, [Cur_Inf|Acc]).


inf_update(Inf, Inf_update) ->
    ["BINF", SID |Parsed_Inf]=string:tokens(Inf, " "),
    Foldl=fun(Cur_Update, Cur_Inf) -> inf_update_cur(Cur_Update, Cur_Inf, []) end,
    New_Inf=lists:foldl(Foldl ,Parsed_Inf, Inf_update), %% call Map to every element of inf string
    string:join(["BINF", SID | New_Inf], " ").

user_login(Client) ->
    Hooked_Args=eadc_plugin:hook(user_login, [{client, Client}]),
    Hooked_Client=get_val(client, Hooked_Args),
    case is_record(Hooked_Client, client) of
	true -> ok;
	_ -> %% logoff
	    return({stop, Client, "Wrong Client: "++thing_to_string({Hooked_Client})})
    end,
     Logoff=eadc_utils:get_val(logoff, Hooked_Args),
    case Logoff of
	'NO KEY' -> ok;
	_ -> return({stop, Client, Logoff})
    end,
    %%spawn(?MODULE, user_login_, [Hooked_Client]),
    user_login_(Hooked_Client),
    ok.

user_login_(Hooked_Client) ->
    Data_to_send=Hooked_Client#client.inf,
    %% lists:foreach(fun(#client{inf=CInf}) ->
    %% 			  eadc_utils:send_to_client(Hooked_Client, CInf)
    %% 		  end, client_all()),

    D=lists:foldl(fun(#client{inf=CInf}, Acc) ->
			  [CInf,10|Acc]
		  end, "", client_all()),
    eadc_utils:send_to_client(Hooked_Client, D),
    Senders=all_senders(),       %% before client_write, so current client
    client_write(Hooked_Client), %% not in the Senders
    %% running select query right after write is bad for performance
    Senders_to_inform=[Hooked_Client#client.sender|Senders],
    eadc_utils:send_to_senders(Senders_to_inform,Data_to_send).

check_sid(Connect,Sid,StateName) ->
    MyRealSid=(catch eadc_utils:sid_to_s(Connect#connect.adcsid)),
    case Sid of
	'NO KEY' -> ok; %% I or H
	MyRealSid -> % == MySid
	    ok;
	WrongSid ->
	    ?DEBUG(error, "Wrong self sid ~p != ~p: ~p", 
		   [MyRealSid,WrongSid,{Connect, Sid}]),
	    case StateName of
		normal ->
		    eadc_utils:error_to_sender(Connect#connect.sender,"Wrong SID");
		_ -> %% critical phase like wait_inf or wait_pass
		    logoff(Connect,{string,eadc_utils:a2s(["ISTA", "240","SID is not correct"])})
	    end,
	    return({[],"Wrong SID"}) %% deny to futher processing
    end.

run_hook(Hook, Senders,Data,Args) ->
    New_Args=eadc_plugin:hook(Hook, [{senders,Senders},{data,Data}|Args]),
    NSenders=eadc_utils:get_val(senders, New_Args),
    NData   =eadc_utils:get_val(data, New_Args),
    case (is_list(NSenders) andalso is_list(NData)) of
	true ->  {NSenders, NData};
	false -> ?DEBUG(error, "Wrong hooked senders/data ~p", [{NSenders,NData}]),
		 {Senders, Data}
    end.


%% PROFILE
profile_start() ->
    fprof:trace([start,{procs,[erlang:whereis(eadc_client)]}]).

profile_stop() ->
    fprof:trace([stop]),
    fprof:profile(),
    fprof:analyse([totals, {dest, "fprof.analysis"}]),
    fprof:stop().

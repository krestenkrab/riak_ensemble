%% -------------------------------------------------------------------
%%
%% Copyright (c) 2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% TODO: Before PR. Add module edoc + doc functions

-module(riak_ensemble_msg).

-export([send_all/4,
         blocking_send_all/4,
         wait_for_quorum/1,
         handle_reply/4,
         quorum_timeout/1,
         reply/3]).

-include_lib("riak_ensemble_types.hrl").

%% -define(OUT(Fmt,Args), io:format(Fmt,Args)).
-define(OUT(Fmt,Args), ok).

%%%===================================================================

-record(msgstate, {awaiting = undefined,
                   timer    = undefined,
                   id       = undefined,
                   views    = [],
                   replies  = []}).

-opaque msg_state() :: #msgstate{}.
-export_type([msg_state/0]).

-type timer() :: reference().
-type reqid() :: reference().
-type msg() :: term().
-type peer_nack()  :: {peer_id(), nack}.
-type msg_from()   :: {riak_ensemble_msg,pid(),reference()}.
-type maybe_from() :: undefined | {pid(),reference()}.

-type future() :: undefined | pid().
-export_type([future/0, msg_from/0]).

%%%===================================================================

-spec send_all(msg(), peer_id(), peer_pids(), views()) -> msg_state().
send_all(_Msg, Id, _Peers=[{Id,_}], _Views) ->
    ?OUT("~p: self-sending~n", [Id]),
    gen_fsm:send_event(self(), {quorum_met, []}),
    #msgstate{awaiting=undefined, timer=undefined, replies={}, id=Id};
send_all(Msg, Id, Peers, Views) ->
    ?OUT("~p/~p: sending to ~p: ~p~n", [Id, self(), Peers, Msg]),
    {ReqId, Request} = make_request(Msg),
    _ = [maybe_send_request(Id, Peer, ReqId, Request) || Peer={PeerId,_} <- Peers,
                                                         PeerId =/= Id],
    Timer = send_after(?ENSEMBLE_TICK, self(), quorum_timeout),
    #msgstate{awaiting=ReqId, timer=Timer, replies=[], id=Id, views=Views}.

%%%===================================================================

-spec maybe_send_request(peer_id(), {peer_id(), maybe_pid()}, reqid(), msg()) -> ok.
maybe_send_request(Id, {PeerId, PeerPid}, ReqId, Event) ->
    case riak_ensemble_test:maybe_drop(Id, PeerId) of
        true ->
            %% TODO: Consider nacking instead
            io:format("Dropping ~p -> ~p~n", [Id, PeerId]),
            ok;
        false ->
            send_request({PeerId, PeerPid}, ReqId, Event)
    end.

-spec send_request({peer_id(), maybe_pid()}, reqid(), msg()) -> ok.
send_request({PeerId, PeerPid}, ReqId, Event) ->
    case PeerPid of
        undefined ->
            ?OUT("~p: Sending offline nack for ~p~n", [self(), PeerId]),
            From = make_from(self(), ReqId),
            reply(From, PeerId, nack);
        _ ->
            ?OUT("~p: Sending to ~p: ~p~n", [self(), PeerId, Event]),
            gen_fsm:send_event(PeerPid, Event)
    end.

%%%===================================================================

-spec reply(msg_from(), peer_id(), any()) -> ok.
reply({riak_ensemble_msg, Sender, ReqId}, Id, Reply) ->
    gen_fsm:send_all_state_event(Sender, {reply, ReqId, Id, Reply}).

%%%===================================================================

-spec blocking_send_all(msg(), peer_id(), peer_pids(), views())
                       -> {future(), msg_state()}.
blocking_send_all(Msg, Id, Peers, Views) ->
    ?OUT("~p: blocking_send_all to ~p: ~p~n", [Id, Peers, Msg]),
    MsgState = #msgstate{awaiting=undefined, timer=undefined, replies=[], views=Views, id=Id},
    Future = case Peers of
                 [{Id,_}] ->
                     undefined;
                 _ ->
                     spawn_link(fun() ->
                                        collector(Msg, Peers, MsgState)
                                end)
             end,
    {Future, MsgState}.

-spec collector(msg(), peer_pids(), msg_state()) -> ok.
collector(Msg, Peers, #msgstate{id=Id, views=Views}) ->
    {ReqId, Request} = make_request(Msg),
    _ = [maybe_send_request(Id, Peer, ReqId, Request) || Peer={PeerId,_} <- Peers,
                                                         PeerId =/= Id],
    collect_replies([], undefined, Id, Views, ReqId).

-spec collect_replies([peer_reply()], maybe_from(), peer_id(), views(), reqid()) -> ok.
collect_replies(Replies, Parent, Id, Views, ReqId) ->
    receive
        {'$gen_all_state_event', Event} ->
            {reply, ReqId, Peer, Reply} = Event,
            check_enough([{Peer, Reply}|Replies], Parent, Id, Views, ReqId);
        {waiting, From, Ref} when is_pid(From), is_reference(Ref) ->
            check_enough(Replies, {From, Ref}, Id, Views, ReqId)
    after ?ENSEMBLE_TICK ->
            collect_timeout(Replies, Parent)
    end.

-spec collect_timeout([peer_reply()], maybe_from()) -> ok.
collect_timeout(Replies, undefined) ->
    receive {waiting, From, Ref} ->
            collect_timeout(Replies, {From, Ref})
    end;
collect_timeout(Replies, {From, Ref}) ->
    From ! {Ref, timeout, Replies},
    ok.

-spec check_enough([peer_reply()], maybe_from(), peer_id(), views(), reqid()) -> ok.
check_enough(Replies, undefined, Id, Views, ReqId) ->
    collect_replies(Replies, undefined, Id, Views, ReqId);
check_enough(Replies, Parent={From, Ref}, Id, Views, ReqId) ->
    case quorum_met(Replies, Id, Views) of
        true ->
            From ! {Ref, ok, Replies},
            ok;
        nack ->
            collect_timeout(Replies, Parent);
        false ->
            collect_replies(Replies, Parent, Id, Views, ReqId)
    end.

-spec wait_for_quorum(future()) -> {quorum_met, [peer_reply()]} |
                                   {timeout, [peer_reply()]}.
wait_for_quorum(undefined) ->
    {quorum_met, []};
wait_for_quorum(Pid) ->
    Ref = make_ref(),
    Pid ! {waiting, self(), Ref},
    receive
        {Ref, ok, Replies} ->
            {Valid, _Nacks} = find_valid(Replies),
            {quorum_met, Valid};
        {Ref, timeout, Replies} ->
            {timeout, Replies}
    end.

%%%===================================================================

-spec handle_reply(any(), peer_id(), any(), msg_state()) -> msg_state().
handle_reply(ReqId, Peer, Reply, MsgState=#msgstate{awaiting=Awaiting}) ->
    case ReqId == Awaiting of
        true ->
            add_reply(Peer, Reply, MsgState);
        false ->
            MsgState
    end.

-spec add_reply(peer_id(), any(), msg_state()) -> msg_state().
add_reply(Peer, Reply, MsgState=#msgstate{timer=Timer}) ->
    Replies = [{Peer, Reply} | MsgState#msgstate.replies],
    case quorum_met(Replies, MsgState) of
        true ->
            cancel_timer(Timer),
            {Valid, _Nacks} = find_valid(Replies),
            gen_fsm:send_event(self(), {quorum_met, Valid}),
            MsgState#msgstate{replies=[], awaiting=undefined, timer=undefined};
        false ->
            MsgState#msgstate{replies=Replies};
        nack ->
            cancel_timer(Timer),
            quorum_timeout(MsgState#msgstate{replies=Replies})
    end.

-spec quorum_timeout(msg_state()) -> msg_state().
quorum_timeout(#msgstate{replies=Replies}) ->
    {Valid, _Nacks} = find_valid(Replies),
    gen_fsm:send_event(self(), {timeout, Valid}),
    #msgstate{awaiting=undefined, timer=undefined, replies=[]}.

%%%===================================================================

-spec quorum_met([peer_reply()], msg_state()) -> true | false | nack.
quorum_met(Replies, #msgstate{id=Id, views=Views}) ->
    quorum_met(Replies, Id, Views).

-spec quorum_met([peer_reply()], peer_id(), views()) -> true | false | nack.
quorum_met(_Replies, _Id, []) ->
    true;
quorum_met(Replies, Id, [Members|Views]) ->
    Filtered = [Reply || Reply={Peer,_} <- Replies,
                         lists:member(Peer, Members)],
    {Valid, Nacks} = find_valid(Filtered),
    Quorum = length(Members) div 2 + 1,
    Heard = case lists:member(Id, Members) of
                true ->
                    length(Valid) + 1;
                false ->
                    length(Valid)
            end,
    if Heard >= Quorum ->
            ?OUT("~p//~nM: ~p~nV: ~p~nN: ~p: view-met~n", [Id, Members, Valid, Nacks]),
            quorum_met(Replies, Id, Views);
       length(Nacks) >= Quorum ->
            ?OUT("~p//~nM: ~p~nV: ~p~nN: ~p: nack~n", [Id, Members, Valid, Nacks]),
            nack;
       (Heard + length(Nacks)) =:= length(Members) ->
            ?OUT("~p//~nM: ~p~nV: ~p~nN: ~p: nack~n", [Id, Members, Valid, Nacks]),
            nack;
       true ->
            ?OUT("~p//~nM: ~p~nV: ~p~nN: ~p: false~n", [Id, Members, Valid, Nacks]),
            false
    end.

-spec find_valid([peer_reply()]) -> {[peer_reply()], [peer_nack()]}.
find_valid(Replies) ->
    {Valid, Nacks} = lists:partition(fun({_, nack}) ->
                                             false;
                                        (_) ->
                                             true
                                     end, Replies),
    {Valid, Nacks}.

%%%===================================================================

-spec make_request(msg()) -> {reqid(), tuple()}.
make_request(Msg) ->
    ReqId = make_ref(),
    From = make_from(self(), ReqId),
    Request = if is_tuple(Msg) ->
                      erlang:append_element(Msg, From);
                 true ->
                      {Msg, From}
              end,
    {ReqId, Request}.

-spec make_from(pid(), reqid()) -> msg_from().
make_from(Pid, ReqId) ->
    {riak_ensemble_msg, Pid, ReqId}.

%%%===================================================================

-spec send_after(timeout(), pid(), msg()) -> timer().
send_after(Time, Dest, Msg) ->
    erlang:send_after(Time, Dest, Msg).

-spec cancel_timer(timer()) -> ok.
cancel_timer(Timer) ->
    case erlang:cancel_timer(Timer) of
        false ->
            receive
                quorum_timeout -> ok
            after
                0 -> ok
            end;
        _ ->
            ok
    end.

%%%-------------------------------------------------------------------
%%% @author sdhillon
%%% @copyright (C) 2016, <COMPANY>
%%% @doc Subscribes to lashup_kv events, filters them against a matchspec, and checks a vclock
%%%
%%% @end
%%% Created : 12. Feb 2016 8:54 PM
%%%-------------------------------------------------------------------
-module(lashup_kv_events_helper).
-author("sdhillon").

%% API
-export([start_link/1, init/1]).

-record(state, {
  match_spec :: ets:match_spec(),
  match_spec_comp :: ets:comp_match_spec(),
  pid :: pid(),
  ref :: reference()
}).
-type state() :: #state{}.

-include("lashup_kv.hrl").

%% We significantly simplified the code here by allowing data to flow "backwards"
%% The time between obtaining the table snapshot and subscribing can drop data

%% The matchspec must be in the format fun({Key}) when GuardSpecs -> true end
start_link(MatchSpec) ->
  Ref = make_ref(),
  MatchSpecCompiled = ets:match_spec_compile(MatchSpec),
  State = #state{pid = self(), match_spec_comp = MatchSpecCompiled, ref = Ref, match_spec = MatchSpec},
  spawn_link(?MODULE, init, [State]),
  {ok, Ref}.

init(State) ->
  ok = mnesia:wait_for_tables([kv], 5000),
  mnesia:subscribe({table, kv, detailed}),
  State1 = dump_events(State),
  loop(State1).

loop(State) ->
  receive
    {mnesia_table_event, {write, _Table = kv, NewRecord, OldRecords, _ActivityId}} ->
      State1 = maybe_process_event(NewRecord, OldRecords, State),
      loop(State1);
    Any ->
      lager:warning("Got something unexpected: ~p", [Any]),
      loop(State)
  end.


%   Event = #{key => Key, map => Map, vclock => VClock, value => Value, ref => Reference},

-spec(maybe_process_event(lashup_kv:kv(), [lashup_kv:kv()], State :: state()) -> state()).
maybe_process_event(NewRecord = #kv{key = Key}, OldRecords, State = #state{match_spec_comp = MatchSpec}) ->
  case ets:match_spec_run([{Key}], MatchSpec) of
    [true] ->
      send_event(NewRecord, OldRecords, State),
      State;
    [] ->
      State
  end.

%% Rewrite the ref and send the event
-spec(send_event(lashup_kv:kv(), [lashup_kv:kv()], state()) -> ok).
send_event(_NewRecord = #kv{key = Key, map = Map}, [], #state{ref = Ref, pid = Pid}) ->
  Value = riak_dt_map:value(Map),
  Event = #{type => ingest_new, key => Key, ref => Ref, value => Value},
  Pid ! {lashup_kv_events, Event},
  ok;
send_event(_NewRecord = #kv{key = Key, map = Map} = _NewRecords,
  [#kv{map = OldMap}] = _OldRecords, #state{ref = Ref, pid = Pid}) ->
  OldValue = riak_dt_map:value(OldMap),
  Value = riak_dt_map:value(Map),
  Event = #{type => ingest_update, key => Key, ref => Ref, value => Value, old_value => OldValue},
  Pid ! {lashup_kv_events, Event},
  ok.

dump_events(State = #state{match_spec = MatchSpec}) ->
  RewrittenMatchspec = rewrite_matchspec(MatchSpec),
  Records = mnesia:dirty_select(kv, RewrittenMatchspec),

  dump_events(Records, State),
  State.

dump_events(Records, State) ->
  lists:foreach(fun(Record) -> send_event(Record, [], State) end, Records).


rewrite_matchspec(MatchSpec) ->
  [{rewrite_head(MatchHead), MatchConditions, ['$_']} || {{MatchHead}, MatchConditions, [true]} <- MatchSpec].


rewrite_head(MatchHead) ->
  RewriteFun =
    fun
      (key) ->
        MatchHead;
      (_FieldName) ->
        '_'
    end,
  MatchHead1 = [RewriteFun(FieldName) || FieldName <- record_info(fields, kv)],
  list_to_tuple([kv | MatchHead1]).


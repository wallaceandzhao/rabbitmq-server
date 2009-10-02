%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2009 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2009 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2009 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%

-module(rabbit_queue_index).

-export([init/1, write_published/4, write_delivered/2, write_acks/2,
         flush_journal/1, read_segment_entries/2]).

-define(MAX_ACK_JOURNAL_ENTRY_COUNT, 32768).
-define(ACK_JOURNAL_FILENAME, "ack_journal.jif").
-define(SEQ_BYTES, 8).
-define(SEQ_BITS, (?SEQ_BYTES * 8)).
-define(SEGMENT_EXTENSION, ".idx").

-define(REL_SEQ_BITS, 14).
-define(SEGMENT_ENTRIES_COUNT, 16384). %% trunc(math:pow(2,?REL_SEQ_BITS))).

%% seq only is binary 00 followed by 14 bits of rel seq id
%% (range: 0 - 16383)
-define(REL_SEQ_ONLY_PREFIX, 00).
-define(REL_SEQ_ONLY_PREFIX_BITS, 2).
-define(REL_SEQ_ONLY_ENTRY_LENGTH_BYTES, 2).

%% publish record is binary 1 followed by a bit for is_persistent,
%% then 14 bits of rel seq id, and 128 bits of md5sum msg id
-define(PUBLISH_PREFIX, 1).
-define(PUBLISH_PREFIX_BITS, 1).

-define(MSG_ID_BYTES, 16). %% md5sum is 128 bit or 16 bytes
-define(MSG_ID_BITS, (?MSG_ID_BYTES * 8)).
%% 16 bytes for md5sum + 2 for seq, bits and prefix
-define(PUBLISH_RECORD_LENGTH_BYTES, ?MSG_ID_BYTES + 2).

%% 1 publish, 1 deliver, 1 ack per msg
-define(SEGMENT_TOTAL_SIZE, ?SEGMENT_ENTRIES_COUNT *
        (?PUBLISH_RECORD_LENGTH_BYTES +
         (2 * ?REL_SEQ_ONLY_ENTRY_LENGTH_BYTES))).

%%----------------------------------------------------------------------------

-record(qistate,
        { dir,
          cur_seg_num,
          cur_seg_hdl,
          journal_ack_count,
          journal_ack_dict,
          journal_handle,
          seg_ack_counts
        }).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(io_device() :: any()).
-type(msg_id() :: binary()).
-type(seq_id() :: integer()).
-type(file_path() :: any()).
-type(int_or_undef() :: integer() | 'undefined').
-type(io_dev_or_undef() :: io_device() | 'undefined').
-type(qistate() :: #qistate { dir               :: file_path(),
                              cur_seg_num       :: int_or_undef(),
                              cur_seg_hdl       :: io_dev_or_undef(),
                              journal_ack_count :: integer(),
                              journal_ack_dict  :: dict(),
                              journal_handle    :: io_device(),
                              seg_ack_counts    :: dict()
                            }).

-spec(init/1 :: (string()) -> qistate()).
-spec(write_published/4 :: (msg_id(), seq_id(), boolean(), qistate())
      -> qistate()).
-spec(write_delivered/2 :: (seq_id(), qistate()) -> qistate()).
-spec(write_acks/2 :: ([seq_id()], qistate()) -> qistate()).
-spec(flush_journal/1 :: (qistate()) -> {boolean(), qistate()}).

-endif.

%%----------------------------------------------------------------------------
%% Public API
%%----------------------------------------------------------------------------

init(Name) ->
    Dir = filename:join(rabbit_mnesia:dir(), Name),
    ok = filelib:ensure_dir(filename:join(Dir, "nothing")),
    AckCounts = scatter_journal(Dir, find_ack_counts(Dir)),
    {ok, JournalHdl} = file:open(filename:join(Dir, ?ACK_JOURNAL_FILENAME),
                                 [raw, binary, delayed_write, write, read]),
    #qistate { dir = Dir,
               cur_seg_num = undefined,
               cur_seg_hdl = undefined,
               journal_ack_count = 0,
               journal_ack_dict = dict:new(),
               journal_handle = JournalHdl,
               seg_ack_counts = AckCounts
             }.

write_published(MsgId, SeqId, IsPersistent, State)
  when is_binary(MsgId) ->
    ?MSG_ID_BYTES = size(MsgId),
    {SegNum, RelSeq} = seq_id_to_seg_and_rel_seq_id(SeqId),
    {Hdl, State1} = get_file_handle_for_seg(SegNum, State),
    ok = file:write(Hdl,
                    <<?PUBLISH_PREFIX:?PUBLISH_PREFIX_BITS,
                     (bool_to_int(IsPersistent)):1,
                     RelSeq:?REL_SEQ_BITS, MsgId/binary>>),
    State1.

write_delivered(SeqId, State) ->
    {SegNum, RelSeq} = seq_id_to_seg_and_rel_seq_id(SeqId),
    {Hdl, State1} = get_file_handle_for_seg(SegNum, State),
    ok = file:write(Hdl,
                    <<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS,
                     RelSeq:?REL_SEQ_BITS>>),
    State1.

write_acks(SeqIds, State = #qistate { journal_handle    = JournalHdl,
                                      journal_ack_dict  = JAckDict,
                                      journal_ack_count = JAckCount }) ->
    {JAckDict1, JAckCount1} =
        lists:foldl(
          fun (SeqId, {JAckDict2, JAckCount2}) ->
                  ok = file:write(JournalHdl, <<SeqId:?SEQ_BITS>>),
                  {add_ack_to_ack_dict(SeqId, JAckDict2), JAckCount2 + 1}
          end, {JAckDict, JAckCount}, SeqIds),
    State1 = State #qistate { journal_ack_dict = JAckDict1,
                              journal_ack_count = JAckCount1 },
    case JAckCount1 > ?MAX_ACK_JOURNAL_ENTRY_COUNT of
        true -> {_Cont, State2} = flush_journal(State1),
                State2;
        false -> State1
    end.

flush_journal(State = #qistate { journal_ack_count = 0 }) ->
    {false, State};
flush_journal(State = #qistate { journal_handle = JournalHdl,
                                 journal_ack_dict = JAckDict,
                                 journal_ack_count = JAckCount,
                                 seg_ack_counts = AckCounts,
                                 dir = Dir }) ->
    [SegNum|_] = dict:fetch_keys(JAckDict),
    Acks = dict:fetch(SegNum, JAckDict),
    SegPath = seg_num_to_path(Dir, SegNum),
    State1 = close_file_handle_for_seg(SegNum, State),
    AckCounts1 = append_acks_to_segment(SegPath, SegNum, AckCounts, Acks),
    JAckCount1 = JAckCount - length(Acks),
    State2 = State1 #qistate { journal_ack_dict = dict:erase(SegNum, JAckDict),
                               journal_ack_count = JAckCount1,
                               seg_ack_counts = AckCounts1 },
    if
        JAckCount1 == 0 ->
            {ok, 0} = file:position(JournalHdl, 0),
            ok = file:truncate(JournalHdl),
            {false, State2};
        JAckCount1 > ?MAX_ACK_JOURNAL_ENTRY_COUNT ->
            flush_journal(State2);
        true ->
            {true, State2}
    end.

read_segment_entries(InitSeqId, State = #qistate { dir = Dir }) ->
    {SegNum, 0} = seq_id_to_seg_and_rel_seq_id(InitSeqId),
    SegPath = seg_num_to_path(Dir, SegNum),
    {SDict, _AckCount} = load_segment(SegNum, SegPath),
    %% deliberately sort the list desc, because foldl will reverse it
    RelSeqs = lists:sort(fun (A, B) -> B < A end, dict:fetch_keys(SDict)),
    {lists:foldl(fun (RelSeq, Acc) ->
                         {MsgId, IsDelivered, IsPersistent} =
                             dict:fetch(RelSeq, SDict),
                        [{index_entry, reconstruct_seq_id(SegNum, RelSeq),
                          MsgId, IsDelivered, IsPersistent, on_disk} | Acc]
                 end, [], RelSeqs),
     State}.

%%----------------------------------------------------------------------------
%% Minor Helpers
%%----------------------------------------------------------------------------

close_file_handle_for_seg(_SegNum,
                          State = #qistate { cur_seg_num = undefined }) ->
    State;
close_file_handle_for_seg(SegNum, State = #qistate { cur_seg_num = SegNum,
                                                     cur_seg_hdl = Hdl }) ->
    ok = file:sync(Hdl),
    ok = file:close(Hdl),
    State #qistate { cur_seg_num = undefined, cur_seg_hdl = undefined };
close_file_handle_for_seg(_SegNum, State) ->
    State.

get_file_handle_for_seg(SegNum, State = #qistate { cur_seg_num = SegNum,
                                                   cur_seg_hdl = Hdl }) ->
    {Hdl, State};
get_file_handle_for_seg(SegNum, State = #qistate { cur_seg_num = CurSegNum }) ->
    State1 = #qistate { dir = Dir } =
        close_file_handle_for_seg(CurSegNum, State),
    {ok, Hdl} = file:open(seg_num_to_path(Dir, SegNum),
                          [binary, raw, append, delayed_write]),
    {Hdl, State1 #qistate { cur_seg_num = SegNum, cur_seg_hdl = Hdl}}.

bool_to_int(true ) -> 1;
bool_to_int(false) -> 0.

seq_id_to_seg_and_rel_seq_id(SeqId) ->
    { SeqId div ?SEGMENT_ENTRIES_COUNT, SeqId rem ?SEGMENT_ENTRIES_COUNT }.

reconstruct_seq_id(SegNum, RelSeq) ->
    (SegNum * ?SEGMENT_ENTRIES_COUNT) + RelSeq.

seg_num_to_path(Dir, SegNum) ->
    SegName = integer_to_list(SegNum),
    filename:join(Dir, SegName ++ ?SEGMENT_EXTENSION).    


%%----------------------------------------------------------------------------
%% Startup Functions
%%----------------------------------------------------------------------------

find_ack_counts(Dir) ->
    SegNumsPaths =
        [{list_to_integer(
            lists:takewhile(fun(C) -> $0 =< C andalso C =< $9 end,
                            SegName)), filename:join(Dir, SegName)}
         || SegName <- filelib:wildcard("*" ++ ?SEGMENT_EXTENSION, Dir)],
    lists:foldl(
      fun ({SegNum, SegPath}, Acc) ->
              case load_segment(SegNum, SegPath) of
                  {_SDict, 0} -> Acc;
                  {_SDict, AckCount} -> dict:store(SegNum, AckCount, Acc)
              end
      end, dict:new(), SegNumsPaths).

scatter_journal(Dir, AckCounts) ->
    JournalPath = filename:join(Dir, ?ACK_JOURNAL_FILENAME),
    case file:open(JournalPath, [read, read_ahead, raw, binary]) of
        {error, enoent} -> AckCounts;
        {ok, Hdl} ->
            ADict = load_journal(Hdl, dict:new()),
            ok = file:close(Hdl),
            {AckCounts1, _Dir} = dict:fold(fun replay_journal_acks_to_segment/3,
                                           {AckCounts, Dir}, ADict),
            ok = file:delete(JournalPath),
            AckCounts1
    end.

load_journal(Hdl, ADict) ->
    case file:read(Hdl, ?SEQ_BYTES) of
        {ok, <<SeqId:?SEQ_BITS>>} ->
            load_journal(Hdl, add_ack_to_ack_dict(SeqId, ADict));
        _ErrOrEoF -> ADict
    end.

add_ack_to_ack_dict(SeqId, ADict) ->
    {SegNum, RelSeq} = seq_id_to_seg_and_rel_seq_id(SeqId),
    dict:update(SegNum, fun(Lst) -> [RelSeq|Lst] end, [RelSeq], ADict).

replay_journal_acks_to_segment(SegNum, Acks, {AckCounts, Dir}) ->
    SegPath = seg_num_to_path(Dir, SegNum),
    {SDict, _AckCount} = load_segment(SegNum, SegPath),
    ValidRelSeqIds = dict:fetch_keys(SDict),
    ValidAcks = sets:intersection(sets:from_list(ValidRelSeqIds),
                                  sets:from_list(Acks)),
    {append_acks_to_segment(SegPath, SegNum, AckCounts,
                            sets:to_list(ValidAcks)),
     Dir}.


%%----------------------------------------------------------------------------
%% Loading Segments
%%----------------------------------------------------------------------------

load_segment(SegNum, SegPath) ->
    case file:open(SegPath, [raw, binary, read_ahead, read]) of
        {error, enoent} -> dict:new();
        {ok, Hdl} ->
            Result = load_segment_entries(SegNum, Hdl, {dict:new(), 0}),
            ok = file:close(Hdl),
            Result
    end.

load_segment_entries(SegNum, Hdl, {SDict, AckCount}) ->
    case file:read(Hdl, 1) of
        {ok, <<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS,
               MSB/bitstring>>} ->
            {ok, LSB} = file:read(Hdl, ?REL_SEQ_ONLY_ENTRY_LENGTH_BYTES - 1),
            <<RelSeq:?REL_SEQ_BITS>> = <<MSB/bitstring, LSB/binary>>,
            load_segment_entries(SegNum, Hdl,
                                 deliver_or_ack_msg(SDict, AckCount, RelSeq));
        {ok, <<?PUBLISH_PREFIX:?PUBLISH_PREFIX_BITS,
               IsPersistentNum:1, MSB/bitstring>>} ->
            %% because we specify /binary, and binaries are complete
            %% bytes, the size spec is in bytes, not bits.
            {ok, <<LSB:1/binary, MsgId:?MSG_ID_BYTES/binary>>} =
                file:read(Hdl, ?PUBLISH_RECORD_LENGTH_BYTES - 1),
            <<RelSeq:?REL_SEQ_BITS>> = <<MSB/bitstring, LSB/binary>>,
            load_segment_entries(
              SegNum, Hdl, {dict:store(RelSeq, {MsgId, false,
                                                1 == IsPersistentNum},
                                       SDict), AckCount});
        _ErrOrEoF -> {SDict, AckCount}
    end.

deliver_or_ack_msg(SDict, AckCount, RelSeq) ->
    case dict:find(RelSeq, SDict) of
        {ok, {MsgId, false, IsPersistent}} ->
            {dict:store(RelSeq, {MsgId, true, IsPersistent}, SDict), AckCount};
        {ok, {_MsgId, true, _IsPersistent}} ->
            {dict:erase(RelSeq, SDict), AckCount + 1}
    end.


%%----------------------------------------------------------------------------
%% Appending Acks to Segments
%%----------------------------------------------------------------------------

append_acks_to_segment(SegPath, SegNum, AckCounts, Acks) ->
    AckCount = case dict:find(SegNum, AckCounts) of
                   {ok, AckCount1} -> AckCount1;
                   error           -> 0
               end,
    case append_acks_to_segment(SegPath, AckCount, Acks) of
        0 -> AckCounts;
        ?SEGMENT_ENTRIES_COUNT -> dict:erase(SegNum, AckCounts);
        AckCount2 -> dict:store(SegNum, AckCount2, AckCounts)
    end.

append_acks_to_segment(SegPath, AckCount, Acks)
  when length(Acks) + AckCount == ?SEGMENT_ENTRIES_COUNT ->
    ok = case file:delete(SegPath) of
             ok -> ok;
             {error, enoent} -> ok
         end,
    ?SEGMENT_ENTRIES_COUNT;
append_acks_to_segment(SegPath, AckCount, Acks)
  when length(Acks) + AckCount < ?SEGMENT_ENTRIES_COUNT ->
    {ok, Hdl} = file:open(SegPath, [raw, binary, delayed_write, append]),
    AckCount1 =
        lists:foldl(
          fun (RelSeq, AckCount2) ->
                  ok = file:write(Hdl,
                                  <<?REL_SEQ_ONLY_PREFIX:?REL_SEQ_ONLY_PREFIX_BITS,
                                   RelSeq:?REL_SEQ_BITS>>),
                  AckCount2 + 1
          end, AckCount, Acks),
    ok = file:sync(Hdl),
    ok = file:close(Hdl),
    AckCount1.

%%% -*- erlang-indent-level: 2 -*-
%%%
%%% %CopyrightBegin%
%%% 
%%% Copyright Ericsson AB 2001-2009. All Rights Reserved.
%%% 
%%% The contents of this file are subject to the Erlang Public License,
%%% Version 1.1, (the "License"); you may not use this file except in
%%% compliance with the License. You should have received a copy of the
%%% Erlang Public License along with this software. If not, it can be
%%% retrieved online at http://www.erlang.org/.
%%% 
%%% Software distributed under the License is distributed on an "AS IS"
%%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%% the License for the specific language governing rights and limitations
%%% under the License.
%%% 
%%% %CopyrightEnd%
%%%
%%% compute def/use sets for x86 insns
%%%
%%% TODO:
%%% - represent EFLAGS (condition codes) use/def by a virtual reg?
%%% - should push use/def %esp?

-ifdef(HIPE_AMD64).
-define(HIPE_X86_DEFUSE,	hipe_amd64_defuse).
-define(HIPE_X86_REGISTERS,	hipe_amd64_registers).
-define(RV,			rax).
-else.
-define(HIPE_X86_DEFUSE,	hipe_x86_defuse).
-define(HIPE_X86_REGISTERS,	hipe_x86_registers).
-define(RV,			eax).
-endif.

-module(?HIPE_X86_DEFUSE).
-export([insn_def/1, insn_use/1]). %% src_use/1]).
-include("../x86/hipe_x86.hrl").

%%%
%%% insn_def(Insn) -- Return set of temps defined by an instruction.
%%%

insn_def(I) ->
  case I of
    #alu{dst=Dst} -> dst_def(Dst);
    #cmovcc{dst=Dst} -> dst_def(Dst);
    #fmove{dst=Dst} -> dst_def(Dst);
    #fp_binop{dst=Dst} -> dst_def(Dst);
    #fp_unop{arg=Arg} -> dst_def(Arg);
    #imul{temp=Temp} -> [Temp];
    #lea{temp=Temp} -> [Temp];
    #move{dst=Dst} -> dst_def(Dst);
    #move64{dst=Dst} -> dst_def(Dst);
    #movsx{dst=Dst} -> dst_def(Dst);
    #movzx{dst=Dst} -> dst_def(Dst);
    #pseudo_call{} -> call_clobbered();
    #pseudo_spill{} -> [];
    #pseudo_tailcall_prepare{} -> tailcall_clobbered();
    #shift{dst=Dst} -> dst_def(Dst);
    %% call, cmp, comment, jcc, jmp_fun, jmp_label, jmp_switch, label
    %% pseudo_jcc, pseudo_tailcall, push, ret
    _ -> []
  end.

dst_def(Dst) ->
  case Dst of
    #x86_temp{} -> [Dst];
    #x86_fpreg{} -> [Dst];
    _ -> []
  end.

call_clobbered() ->
  [hipe_x86:mk_temp(R, T)
   || {R,T} <- ?HIPE_X86_REGISTERS:call_clobbered()].

tailcall_clobbered() ->
  [hipe_x86:mk_temp(R, T)
   || {R,T} <- ?HIPE_X86_REGISTERS:tailcall_clobbered()].

%%%
%%% insn_use(Insn) -- Return set of temps used by an instruction.
%%%

insn_use(I) ->
  case I of
    #alu{src=Src,dst=Dst} -> addtemp(Src, addtemp(Dst, []));
    #call{'fun'=Fun} -> addtemp(Fun, []);
    #cmovcc{src=Src, dst=Dst} -> addtemp(Src, dst_use(Dst));
    #cmp{src=Src, dst=Dst} -> addtemp(Src, addtemp(Dst, []));
    #fmove{src=Src,dst=Dst} -> addtemp(Src, dst_use(Dst));
    #fp_unop{arg=Arg} -> addtemp(Arg, []);
    #fp_binop{src=Src,dst=Dst} -> addtemp(Src, addtemp(Dst, []));
    #imul{imm_opt=ImmOpt,src=Src,temp=Temp} ->
      addtemp(Src, case ImmOpt of [] -> addtemp(Temp, []); _ -> [] end);
    #jmp_fun{'fun'=Fun} -> addtemp(Fun, []);
    #jmp_switch{temp=Temp, jtab=JTab} -> addtemp(Temp, addtemp(JTab, []));
    #lea{mem=Mem} -> addtemp(Mem, []);
    #move{src=Src,dst=Dst} -> addtemp(Src, dst_use(Dst));
    #move64{} -> [];
    #movsx{src=Src,dst=Dst} -> addtemp(Src, dst_use(Dst));
    #movzx{src=Src,dst=Dst} -> addtemp(Src, dst_use(Dst));
    #pseudo_call{'fun'=Fun,sdesc=#x86_sdesc{arity=Arity}} ->
      addtemp(Fun, arity_use(Arity));
    #pseudo_spill{args=Args} -> Args;
    #pseudo_tailcall{'fun'=Fun,arity=Arity,stkargs=StkArgs} ->
      addtemp(Fun, addtemps(StkArgs, addtemps(tailcall_clobbered(),
					      arity_use(Arity))));
    #push{src=Src} -> addtemp(Src, []);
    #ret{} -> [hipe_x86:mk_temp(?HIPE_X86_REGISTERS:?RV(), 'tagged')];
    #shift{src=Src,dst=Dst} -> addtemp(Src, addtemp(Dst, []));
    %% comment, jcc, jmp_label, label, pseudo_jcc, pseudo_tailcall_prepare
    _ -> []
  end.

arity_use(Arity) ->
  [hipe_x86:mk_temp(R, 'tagged')
   || R <- ?HIPE_X86_REGISTERS:args(Arity)].

dst_use(Dst) ->
  case Dst of
    #x86_mem{base=Base,off=Off} -> addbase(Base, addtemp(Off, []));
    _ -> []
  end.

%%%
%%% src_use(Src) -- Return set of temps used by a source operand.
%%%

%% src_use(Src) ->
%%   addtemp(Src, []).

%%%
%%% Auxiliary operations on sets of temps
%%%

addtemps([Arg|Args], Set) ->
  addtemps(Args, addtemp(Arg, Set));
addtemps([], Set) ->
  Set.

addtemp(Arg, Set) ->
  case Arg of
    #x86_temp{} -> add(Arg, Set);
    #x86_mem{base=Base,off=Off} -> addtemp(Off, addbase(Base, Set));
    #x86_fpreg{} -> add(Arg, Set);
    _ -> Set
  end.

addbase(Base, Set) ->
  case Base of
    [] -> Set;
    _ -> addtemp(Base, Set)
  end.

add(Arg, Set) ->
  case lists:member(Arg, Set) of
    false -> [Arg|Set];
    _ -> Set
  end.

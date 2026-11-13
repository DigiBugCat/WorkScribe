---------------------------- MODULE CodexSession ----------------------------
(***************************************************************************)
(* The client side of WorkScribe's text generation over `codex app-server` *)
(* (JSON-RPC, one object per line over the child's stdin and stdout).      *)
(*                                                                         *)
(* Code: Sources/WorkScribeCore/Codex/CodexSession.swift is a pure reducer *)
(* (state, event) -> effects.  Each client action below names the `handle` *)
(* case or private method it stands for.  The server, the pipe and the     *)
(* callers are the environment.  One generation = one ephemeral thread =   *)
(* one turn.                                                               *)
(*                                                                         *)
(* Abstractions.  The isolation check (no tool servers, and per thread:    *)
(* read-only sandbox, no approvals, no instruction files) is one "check"   *)
(* message that the server answers ok or bad.  The account is left out: a  *)
(* signed-out account is a turn that fails, and signing in or out does not *)
(* touch a request (see the reducer's tests for those).  Starting the      *)
(* process ahead of a request (.start) and letting an idle one go (.idle)  *)
(* are also left out: both only happen with no request in hand.  Text is a *)
(* count of deltas.                                                        *)
(* Thread ids are <<spawn number, generation>>, so ids are never reused    *)
(* across processes, as with the server's UUIDs.                           *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Gens,              \* generation ids (callers)
          MaxSpawns,         \* how many times the process may be started
          MaxDeltas,         \* text deltas the server may emit per turn
          ServerMayUseTools, \* TRUE: the server may emit a tool item or an approval request
          CheckMayFail,      \* TRUE: the isolation check may come back bad
          Mutation           \* "none", or the name of one guard to remove (see the end of the file)

VARIABLES proc,      \* client's view: "down" | "starting" | "checking" | "ready" | "unsafe"
          spawns,    \* processes started so far
          gen,       \* gen[g] = [st, out]
          early,     \* generations cancelled before their request arrived
          resumed,   \* resumed[g]: times the caller's continuation was resumed
          route,     \* thread id -> generation receiving its notifications
          pending,   \* in-flight requests the client still expects a reply to
          c2s, s2c,  \* the two pipes, FIFO
          alive,     \* the server process is running
          sthread,   \* server: thread id -> "none" | "idle" | "active" | "done"
          sdeltas,   \* server: deltas emitted so far per thread
          stooled,   \* server: threads that already emitted their one tool event
          \* history variables, for the properties only
          textSeen,  \* deltas delivered to each caller
          tooled,    \* generations whose turn showed a tool item or a server request
          sentUnsafe \* a prompt was sent on a connection that was not verified

vars == <<proc, spawns, gen, early, resumed, route, pending, c2s, s2c, alive, sthread, sdeltas, stooled,
          textSeen, tooled, sentUnsafe>>

Threads == {<<n, g>> : n \in 1..MaxSpawns, g \in Gens}
InFlight == {"threadReq", "turnReq", "running"}

Init ==
    /\ proc = "down" /\ spawns = 0
    /\ gen = [g \in Gens |-> [st |-> "new", out |-> "none"]]
    /\ early = {}
    /\ resumed = [g \in Gens |-> 0]
    /\ route = [t \in Threads |-> "none"]
    /\ pending = {}
    /\ c2s = <<>> /\ s2c = <<>>
    /\ alive = FALSE
    /\ sthread = [t \in Threads |-> "none"]
    /\ sdeltas = [t \in Threads |-> 0]
    /\ stooled = {}
    /\ textSeen = [g \in Gens |-> 0]
    /\ tooled = {}
    /\ sentUnsafe = FALSE

(***************************************************************************)
(* Helpers                                                                 *)
(***************************************************************************)
\* `finish`: resume the caller of every generation in S with outcome `out`.
Finish(S, out) ==
    /\ gen' = [g \in Gens |-> IF g \in S THEN [st |-> "finished", out |-> out] ELSE gen[g]]
    /\ resumed' = [g \in Gens |-> IF g \in S THEN resumed[g] + 1 ELSE resumed[g]]

ThreadOf(g) == <<spawns, g>>
Send(m) == c2s' = IF alive THEN Append(c2s, m) ELSE c2s   \* a write to a dead process is lost

(***************************************************************************)
(* Callers                                                                 *)
(***************************************************************************)
\* .generate: a caller asks for text.  It fails at once when it was already cancelled, or the
\* connection is unsafe.
Request(g) ==
    /\ gen[g].st = "new"
    /\ IF g \in early THEN Finish({g}, "cancelled")
       ELSE IF proc = "unsafe" THEN Finish({g}, "failed")
       ELSE /\ gen' = [gen EXCEPT ![g].st = "waiting"] /\ UNCHANGED resumed
    /\ UNCHANGED <<proc, spawns, early, route, pending, c2s, s2c, alive, sthread, sdeltas, stooled, textSeen, tooled, sentUnsafe>>

\* .cancel before .generate (a task cancelled as it starts): remembered.
CancelEarly(g) ==
    /\ gen[g].st = "new" /\ g \notin early
    /\ early' = early \cup {g}
    /\ UNCHANGED <<proc, spawns, gen, resumed, route, pending, c2s, s2c, alive, sthread, sdeltas, stooled, textSeen, tooled, sentUnsafe>>

\* `abandon`: the caller is resumed now; the server is told when there is a turn to stop.
Abandon(g, out) ==
    /\ Finish({g}, out)
    /\ route' = IF Mutation = "keepRoute" THEN route ELSE [t \in Threads |-> IF route[t] = g THEN "none" ELSE route[t]]
    /\ IF gen[g].st = "running" THEN Send([type |-> "interrupt", t |-> ThreadOf(g)]) ELSE UNCHANGED c2s
    \* threadReq / turnReq: the reply is still expected and triggers the cleanup (Receive).
    /\ UNCHANGED <<proc, spawns, early, pending, s2c, alive, sthread, sdeltas, stooled, textSeen, tooled, sentUnsafe>>

\* .cancel
Cancel(g) == gen[g].st \in {"waiting"} \cup InFlight /\ Abandon(g, "cancelled")
\* .timeout: no progress for too long.  A request still waiting for the process is covered by
\* HandshakeTimeout.
Timeout(g) == Mutation # "noTimeout" /\ gen[g].st \in InFlight /\ Abandon(g, "failed")
\* `append` reaching the caller's stop condition (stop marker, first line, length): the caller
\* has all it asked for; it gets the text and the turn is stopped.
StopEarly(g) == gen[g].st = "running" /\ textSeen[g] > 0 /\ Abandon(g, "text")

(***************************************************************************)
(* Client: process lifecycle                                               *)
(***************************************************************************)
\* `ensureStarted`
Spawn ==
    /\ proc = "down" /\ spawns < MaxSpawns
    /\ \E g \in Gens : gen[g].st = "waiting"
    /\ spawns' = spawns + 1
    /\ proc' = "starting" /\ alive' = TRUE
    /\ c2s' = <<[type |-> "initialize"]>> /\ s2c' = <<>>
    /\ pending' = {}
    /\ UNCHANGED <<gen, early, resumed, route, sthread, sdeltas, stooled, textSeen, tooled, sentUnsafe>>

\* `processGone` once the attempts are used up: whoever is waiting is told.
GiveUp ==
    /\ proc = "down" /\ spawns = MaxSpawns
    /\ \E g \in Gens : gen[g].st = "waiting"
    /\ Finish({g \in Gens : gen[g].st = "waiting"}, "failed")
    /\ UNCHANGED <<proc, spawns, early, route, pending, c2s, s2c, alive, sthread, sdeltas, stooled, textSeen, tooled, sentUnsafe>>

\* .handshakeTimeout: a process that does not finish its handshake is killed.
HandshakeTimeout ==
    /\ proc \in {"starting", "checking"}
    /\ proc' = "down" /\ alive' = FALSE /\ c2s' = <<>> /\ s2c' = <<>> /\ pending' = {}
    /\ UNCHANGED <<spawns, gen, early, resumed, route, sthread, sdeltas, stooled, textSeen, tooled, sentUnsafe>>

\* `dispatch`: start a thread for a waiting generation once the connection is verified.
Dispatch(g) ==
    /\ proc \in {"ready", "readyUnverified"} /\ gen[g].st = "waiting"
    /\ gen' = [gen EXCEPT ![g].st = "threadReq"]
    /\ pending' = pending \cup {[kind |-> "thread", g |-> g]}
    /\ Send([type |-> "threadStart", g |-> g])
    /\ UNCHANGED <<proc, spawns, early, resumed, route, s2c, alive, sthread, sdeltas, stooled, textSeen, tooled, sentUnsafe>>

\* `goUnsafe`.  Fail closed: the connection showed something a text-only thread must never
\* have.  Every caller is told, nothing more is sent, the process is killed.
GoUnsafe(extraTooled) ==
    /\ proc' = "unsafe"
    /\ Finish({g \in Gens : gen[g].st \in {"waiting"} \cup InFlight}, "failed")
    /\ route' = [t \in Threads |-> "none"]
    /\ pending' = {}
    /\ alive' = FALSE /\ c2s' = <<>> /\ s2c' = <<>>
    /\ tooled' = tooled \cup extraTooled
    /\ UNCHANGED <<spawns, early, sthread, sdeltas, stooled, textSeen, sentUnsafe>>

\* .disconnect: the sign-in was taken away from outside (the person stopped sharing their Codex
\* sign-in with WorkScribe).  Everyone is told and the process ends; the next request starts a
\* new one, which reads the account again.
Disconnect ==
    /\ proc # "unsafe"
    /\ proc' = "down"
    /\ Finish({g \in Gens : gen[g].st \in {"waiting"} \cup InFlight}, "failed")
    /\ route' = [t \in Threads |-> "none"] /\ pending' = {}
    /\ alive' = FALSE /\ c2s' = <<>> /\ s2c' = <<>>
    /\ UNCHANGED <<spawns, early, sthread, sdeltas, stooled, textSeen, tooled, sentUnsafe>>

(***************************************************************************)
(* Client: one line from the server (.received, .exited)                   *)
(***************************************************************************)
Receive ==
    /\ s2c # <<>>
    /\ LET m == Head(s2c) rest == Tail(s2c) IN
       CASE m.type = "eof" ->
              \* .exited: every in-flight caller is told; waiting ones may get a new process.
              /\ proc' = "down"
              /\ Finish(IF Mutation = "eofSilent" THEN {} ELSE {g \in Gens : gen[g].st \in InFlight}, "failed")
              /\ route' = [t \in Threads |-> "none"] /\ pending' = {}
              /\ s2c' = <<>> /\ c2s' = <<>> /\ alive' = FALSE
              /\ UNCHANGED <<spawns, early, sthread, sdeltas, stooled, textSeen, tooled, sentUnsafe>>
         [] m.type = "initOk" ->
              /\ proc = "starting"
              /\ proc' = "checking" /\ s2c' = rest
              /\ Send([type |-> "check"])
              /\ UNCHANGED <<spawns, gen, early, resumed, route, pending, alive, sthread, sdeltas, stooled, textSeen, tooled, sentUnsafe>>
         [] m.type = "checkOk" ->
              /\ proc = "checking"
              /\ proc' = "ready" /\ s2c' = rest
              /\ UNCHANGED <<spawns, gen, early, resumed, route, pending, c2s, alive, sthread, sdeltas, stooled, textSeen, tooled, sentUnsafe>>
         [] m.type = "checkBad" ->
              /\ proc = "checking"
              /\ IF Mutation = "ignoreCheck"
                 THEN /\ proc' = "readyUnverified" /\ s2c' = rest
                      /\ UNCHANGED <<spawns, gen, early, resumed, route, pending, c2s, alive, sthread, sdeltas, stooled, textSeen, tooled, sentUnsafe>>
                 ELSE GoUnsafe({})
         [] m.type = "threadStarted" ->
              \* The reply binds the thread to its generation in the same step, so no later
              \* notification can arrive before the route exists.
              /\ s2c' = rest
              /\ IF gen[m.g].st = "threadReq" \/ Mutation = "trustAbandoned"
                 THEN /\ gen' = [gen EXCEPT ![m.g].st = "turnReq"]
                      /\ route' = [route EXCEPT ![m.t] = m.g]
                      /\ pending' = (pending \ {[kind |-> "thread", g |-> m.g]}) \cup {[kind |-> "turn", g |-> m.g]}
                      /\ Send([type |-> "turnStart", g |-> m.g, t |-> m.t])
                      /\ sentUnsafe' = (sentUnsafe \/ proc # "ready")
                 ELSE \* abandoned while the request was in flight: release the thread, send no prompt
                      /\ pending' = pending \ {[kind |-> "thread", g |-> m.g]}
                      /\ Send([type |-> "unsubscribe", t |-> m.t])
                      /\ UNCHANGED <<gen, route, sentUnsafe>>
              /\ UNCHANGED <<proc, spawns, early, resumed, alive, sthread, sdeltas, stooled, textSeen, tooled>>
         [] m.type = "turnStarted" ->
              /\ s2c' = rest
              /\ pending' = pending \ {[kind |-> "turn", g |-> m.g]}
              /\ IF gen[m.g].st = "turnReq"
                 THEN /\ gen' = [gen EXCEPT ![m.g].st = "running"] /\ UNCHANGED c2s
                 ELSE \* abandoned while the turn was starting: now that it has an id, stop it
                      /\ Send([type |-> "interrupt", t |-> m.t]) /\ UNCHANGED gen
              /\ UNCHANGED <<proc, spawns, early, resumed, route, alive, sthread, sdeltas, stooled, textSeen, tooled, sentUnsafe>>
         [] m.type = "delta" ->
              /\ s2c' = rest
              /\ IF route[m.t] # "none"
                 THEN textSeen' = [textSeen EXCEPT ![route[m.t]] = @ + 1]
                 ELSE UNCHANGED textSeen     \* late notification for an abandoned turn: dropped
              /\ UNCHANGED <<proc, spawns, gen, early, resumed, route, pending, c2s, alive, sthread, sdeltas, stooled, tooled, sentUnsafe>>
         [] m.type \in {"toolItem", "serverRequest"} ->
              \* Any tool activity, on any thread, routed or not, condemns the connection.
              IF Mutation = "toolIgnored"
              THEN /\ s2c' = rest
                   /\ tooled' = tooled \cup (IF route[m.t] # "none" THEN {route[m.t]} ELSE {})
                   /\ UNCHANGED <<proc, spawns, gen, early, resumed, route, pending, c2s, alive, sthread, sdeltas, stooled, textSeen, sentUnsafe>>
              ELSE GoUnsafe(IF route[m.t] # "none" THEN {route[m.t]} ELSE {})
         [] m.type = "turnCompleted" ->
              /\ s2c' = rest
              /\ IF route[m.t] # "none"
                 THEN /\ Finish({route[m.t]}, IF m.status = "completed" THEN "text" ELSE "failed")
                      /\ route' = [route EXCEPT ![m.t] = "none"]
                      /\ Send([type |-> "unsubscribe", t |-> m.t])
                 ELSE UNCHANGED <<gen, resumed, route, c2s>>
              /\ UNCHANGED <<proc, spawns, early, pending, alive, sthread, sdeltas, stooled, textSeen, tooled, sentUnsafe>>

(***************************************************************************)
(* Server and pipe (environment)                                           *)
(***************************************************************************)
ServerRead ==
    /\ alive /\ c2s # <<>>
    /\ LET m == Head(c2s) IN
       /\ c2s' = Tail(c2s)
       /\ CASE m.type = "initialize" -> s2c' = Append(s2c, [type |-> "initOk"]) /\ UNCHANGED <<sthread, sdeltas>>
            [] m.type = "check" ->
                 /\ \E ok \in (IF CheckMayFail THEN {TRUE, FALSE} ELSE {TRUE}) :
                        s2c' = Append(s2c, [type |-> IF ok THEN "checkOk" ELSE "checkBad"])
                 /\ UNCHANGED <<sthread, sdeltas>>
            [] m.type = "threadStart" ->
                 /\ sthread' = [sthread EXCEPT ![<<spawns, m.g>>] = "idle"]
                 /\ s2c' = Append(s2c, [type |-> "threadStarted", g |-> m.g, t |-> <<spawns, m.g>>])
                 /\ UNCHANGED sdeltas
            [] m.type = "turnStart" ->
                 /\ sthread' = [sthread EXCEPT ![m.t] = "active"]
                 /\ s2c' = Append(s2c, [type |-> "turnStarted", g |-> m.g, t |-> m.t])
                 /\ UNCHANGED sdeltas
            [] m.type = "interrupt" ->
                 /\ IF sthread[m.t] = "active"
                    THEN /\ sthread' = [sthread EXCEPT ![m.t] = "done"]
                         /\ s2c' = Append(s2c, [type |-> "turnCompleted", t |-> m.t, status |-> "interrupted"])
                    ELSE UNCHANGED <<sthread, s2c>>
                 /\ UNCHANGED sdeltas
            [] m.type = "unsubscribe" -> UNCHANGED <<s2c, sthread, sdeltas>>
    /\ UNCHANGED <<proc, spawns, gen, early, resumed, route, pending, alive, stooled, textSeen, tooled, sentUnsafe>>

ServerDelta(t) ==
    /\ alive /\ sthread[t] = "active" /\ sdeltas[t] < MaxDeltas
    /\ sdeltas' = [sdeltas EXCEPT ![t] = @ + 1]
    /\ s2c' = Append(s2c, [type |-> "delta", t |-> t])
    /\ UNCHANGED <<proc, spawns, gen, early, resumed, route, pending, c2s, alive, sthread, stooled, textSeen, tooled, sentUnsafe>>

\* One tool event per thread is enough to exercise the rule, and keeps the pipe bounded.
ServerTool(t) ==
    /\ ServerMayUseTools /\ alive /\ sthread[t] = "active" /\ t \notin stooled
    /\ stooled' = stooled \cup {t}
    /\ \E kind \in {"toolItem", "serverRequest"} : s2c' = Append(s2c, [type |-> kind, t |-> t])
    /\ UNCHANGED <<proc, spawns, gen, early, resumed, route, pending, c2s, alive, sthread, sdeltas, textSeen, tooled, sentUnsafe>>

ServerComplete(t) ==
    /\ alive /\ sthread[t] = "active"
    /\ sthread' = [sthread EXCEPT ![t] = "done"]
    /\ \E status \in {"completed", "failed"} :
           s2c' = Append(s2c, [type |-> "turnCompleted", t |-> t, status |-> status])
    /\ UNCHANGED <<proc, spawns, gen, early, resumed, route, pending, c2s, alive, sdeltas, stooled, textSeen, tooled, sentUnsafe>>

\* The process dies (crash, kill, the person quitting Codex).  What it already wrote stays readable.
ServerCrash ==
    /\ alive
    /\ alive' = FALSE /\ c2s' = <<>>
    /\ s2c' = Append(s2c, [type |-> "eof"])
    /\ UNCHANGED <<proc, spawns, gen, early, resumed, route, pending, sthread, sdeltas, stooled, textSeen, tooled, sentUnsafe>>

Next ==
    \/ \E g \in Gens : Request(g) \/ CancelEarly(g) \/ Cancel(g) \/ Timeout(g) \/ StopEarly(g) \/ Dispatch(g)
    \/ Spawn \/ GiveUp \/ Receive \/ HandshakeTimeout \/ Disconnect
    \/ ServerRead \/ ServerCrash
    \/ \E t \in Threads : ServerDelta(t) \/ ServerTool(t) \/ ServerComplete(t)

\* The client always makes progress on what it can do alone.  Nothing is assumed of the server:
\* it may stall or die at any point, and the two timeouts are what cover that.
Fairness ==
    /\ WF_vars(Receive) /\ WF_vars(Spawn) /\ WF_vars(GiveUp) /\ WF_vars(HandshakeTimeout)
    /\ \A g \in Gens : WF_vars(Dispatch(g)) /\ WF_vars(Timeout(g))

Spec == Init /\ [][Next]_vars /\ Fairness

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
TypeOK ==
    /\ proc \in {"down", "starting", "checking", "ready", "unsafe"}
    /\ \A g \in Gens : gen[g].st \in {"new", "waiting", "threadReq", "turnReq", "running", "finished"}
    /\ \A g \in Gens : gen[g].out \in {"none", "text", "failed", "cancelled"}

\* P1. A caller is resumed exactly once: never twice, and "finished" means it was.
ExactlyOnce == \A g \in Gens : /\ resumed[g] <= 1
                               /\ (gen[g].st = "finished") <=> (resumed[g] = 1)
                               /\ (gen[g].st = "finished") <=> (gen[g].out # "none")

\* P2. Text is never handed over from a turn that showed a tool.
NoTextFromToolTurn == \A g \in tooled : gen[g].out # "text"

\* P3. With no usable process, nobody is left waiting on a reply that cannot come.
NoOrphanWhenDown == (proc \in {"down", "unsafe"}) => \A g \in Gens : gen[g].st \notin InFlight

\* P4. Nothing is kept for a finished generation: no route, so no late message can reach it.
NoStaleRoute == \A t \in Threads : route[t] # "none" => gen[route[t]].st \in {"turnReq", "running"}

\* P5. A prompt (turn/start) is only ever written to a connection that passed the isolation check.
PromptOnlyWhenVerified == ~sentUnsafe

\* P6. Fail closed: once unsafe, nothing is in flight, nothing is queued to be sent, the process is dead.
UnsafeIsQuiet == (proc = "unsafe") => (c2s = <<>> /\ ~alive /\ \A g \in Gens : gen[g].st \in {"new", "finished"})

\* P7. Text only comes from a turn that produced some: a caller told "text" saw a delta or a completed turn.
TextHasASource == \A g \in Gens : gen[g].out = "text" => \E n \in 1..MaxSpawns : sthread[<<n, g>>] \in {"active", "done"}

\* P8. Every request ends: with text, an error, or the caller's own cancel.
EveryRequestEnds == \A g \in Gens : (gen[g].st = "waiting") ~> (gen[g].st = "finished")

(***************************************************************************)
(* Mutations.  With Mutation = "none" every property above holds.  Each    *)
(* other value removes one guard, and the property named must then fail:   *)
(*   keepRoute       Abandon leaves the route          -> ExactlyOnce      *)
(*   trustAbandoned  thread reply ignores "abandoned"  -> ExactlyOnce      *)
(*   toolIgnored     tool items are dropped            -> NoTextFromToolTurn *)
(*   eofSilent       process exit tells nobody         -> NoOrphanWhenDown *)
(*   noTimeout       nothing watches a silent turn     -> EveryRequestEnds *)
(*   ignoreCheck     a failed check is treated as ok   -> PromptOnlyWhenVerified *)
(*                                                                         *)
(* Starting threads before the check has answered would NOT break the last *)
(* one: the pipes are FIFO, so the reply to thread/start always arrives    *)
(* after the check's reply, and the prompt is only sent on that reply.     *)
(***************************************************************************)

\* Reachability: each of these is expected to be VIOLATED, which shows the interesting states are reached.
NeverText == \A g \in Gens : gen[g].out # "text"
NeverUnsafe == proc # "unsafe"
NeverAbandonedMidStart == \A g \in Gens : ~(gen[g].st = "finished" /\ [kind |-> "turn", g |-> g] \in pending)
NeverLateMessage == ~(s2c # <<>> /\ Head(s2c).type \in {"delta", "turnCompleted"} /\ route[Head(s2c).t] = "none")
=============================================================================

----------------------------- MODULE ScreenWatch -----------------------------
(***************************************************************************)
(* WorkScribe's screen capture: when a window is read, and whether what    *)
(* was read may be kept.                                                   *)
(*                                                                         *)
(* Code: Sources/WorkScribeCore/ScreenWatch.swift is a pure reducer; each  *)
(* client action below names the `handle` case it stands for.  The person, *)
(* the window server's notifications (which arrive late) and the reader    *)
(* (which takes time) are the environment.                                 *)
(*                                                                         *)
(* The question this module answers is the one tests rarely reach: the     *)
(* person switches to a password manager, or opens a private window,       *)
(* while a read is already under way and before the notification of the    *)
(* switch has been delivered.  Can that read's text be kept?               *)
(*                                                                         *)
(* Abstractions.  Time is left out: the settle delay, the gap between      *)
(* reads and the idle interval only postpone a read, so here a read may    *)
(* be asked for whenever the gate allows.  The typing-forever case that    *)
(* `maximumWait` exists for is therefore covered by a test of the reducer, *)
(* not by this model.  Text is reduced to which app it came from and       *)
(* whether its window was private.  "Private" is whatever the title        *)
(* heuristic recognises; a private window it does not recognise is, to     *)
(* this model, an ordinary window.                                         *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Apps,        \* applications
          Denied,      \* the deny list (a subset of Apps)
          Moves,       \* how many things the person may do (switch app, toggle private, lock, unlock)
          Controls,    \* how many times capture may be started, stopped, paused or resumed
          Losses,      \* how many reads may never come back
          Mutation     \* "none", or the name of one rule to remove (see the end of the file)

VARIABLES
    \* the world
    wFront,     \* the app really in front
    wPrivate,   \* wPrivate[a]: a's focused window is a private one
    wLocked,
    notes,      \* notifications not yet delivered, in order
    moves,      \* moves left
    \* the reducer (ScreenWatch)
    running, paused, locked,
    front,      \* the app it believes is in front ("none" before the first notification)
    priv,       \* it believes that app's window is private
    epoch,      \* bumped by anything that makes an earlier read stale
    reading,    \* token of the read it is waiting for, or 0
    controls,   \* controls left
    giveups,    \* times it may still give up on a read that is merely slow
    \* the reader
    asked,      \* reads asked for, not yet performed: [token, app, askedOpen]
    results,    \* reads performed, not yet returned.  `app` and `private` are what the reader
                \* reports; `fromApp` and `fromPrivate` are whose pixels or text it really holds.
    losses,
    \* history
    kept        \* what was really kept: [app, private, readOpen]

vars == <<wFront, wPrivate, wLocked, notes, moves, running, paused, locked, front, priv, epoch, reading,
          controls, giveups, asked, results, losses, kept>>
world == <<wFront, wPrivate, wLocked, notes, moves>>
reader == <<asked, results, losses>>

Open == running /\ ~paused /\ ~locked                    \* `open`
Permitted == front # "none" /\ front \notin Denied /\ ~priv   \* `permitted`

Init ==
    /\ wFront \in Apps /\ wPrivate = [a \in Apps |-> FALSE] /\ wLocked = FALSE
    /\ notes = <<[kind |-> "front", app |-> wFront, private |-> FALSE]>>
    /\ moves = Moves
    /\ running = FALSE /\ paused = FALSE /\ locked = FALSE
    /\ front = "none" /\ priv = FALSE /\ epoch = 1 /\ reading = 0 /\ controls = Controls /\ giveups = 1
    /\ asked = {} /\ results = {} /\ losses = Losses
    /\ kept = {}

(***************************************************************************)
(* The person.  Every action is noticed later, through `notes`.            *)
(***************************************************************************)
SwitchApp(a) ==
    /\ moves > 0 /\ a # wFront
    /\ wFront' = a /\ moves' = moves - 1
    /\ notes' = Append(notes, [kind |-> "front", app |-> a, private |-> wPrivate[a]])
    /\ UNCHANGED <<wPrivate, wLocked, running, paused, locked, front, priv, epoch, reading, controls, giveups, asked, results, losses, kept>>

\* Open or leave a private window in the app in front.
TogglePrivate ==
    /\ moves > 0
    /\ wPrivate' = [wPrivate EXCEPT ![wFront] = ~@] /\ moves' = moves - 1
    /\ notes' = Append(notes, [kind |-> "front", app |-> wFront, private |-> ~wPrivate[wFront]])
    /\ UNCHANGED <<wFront, wLocked, running, paused, locked, front, priv, epoch, reading, controls, giveups, asked, results, losses, kept>>

ToggleLock ==
    /\ moves > 0
    /\ wLocked' = ~wLocked /\ moves' = moves - 1
    /\ notes' = Append(notes, [kind |-> "lock", value |-> ~wLocked])
    /\ UNCHANGED <<wFront, wPrivate, running, paused, locked, front, priv, epoch, reading, controls, giveups, asked, results, losses, kept>>

(***************************************************************************)
(* The reducer                                                             *)
(***************************************************************************)
\* `shut`: pause, lock, stop.  Whatever is being read is stale.
Shut == epoch' = epoch + 1 /\ reading' = 0

\* .start / .stop
Start ==
    /\ controls > 0 /\ ~running
    /\ running' = TRUE /\ epoch' = epoch + 1 /\ reading' = 0 /\ controls' = controls - 1
    /\ UNCHANGED <<world, paused, locked, front, priv, giveups, reader, kept>>
Stop ==
    /\ controls > 0 /\ running
    /\ running' = FALSE /\ controls' = controls - 1
    /\ IF Mutation = "keepAcrossPause" THEN UNCHANGED <<epoch, reading>> ELSE Shut
    /\ UNCHANGED <<world, paused, locked, front, priv, giveups, reader, kept>>

\* .paused(true) / .paused(false)
Pause ==
    /\ controls > 0 /\ ~paused
    /\ paused' = TRUE /\ controls' = controls - 1
    /\ IF Mutation = "keepAcrossPause" THEN UNCHANGED <<epoch, reading>> ELSE Shut
    /\ UNCHANGED <<world, running, locked, front, priv, giveups, reader, kept>>
Resume ==
    /\ controls > 0 /\ paused
    /\ paused' = FALSE /\ controls' = controls - 1
    /\ IF Mutation = "keepAcrossPause" THEN UNCHANGED <<epoch, reading>> ELSE Shut
    /\ UNCHANGED <<world, running, locked, front, priv, giveups, reader, kept>>

\* .frontmost and .locked: one notification is delivered.
Notice ==
    /\ notes # <<>>
    /\ LET n == Head(notes) IN
       /\ notes' = Tail(notes)
       /\ IF n.kind = "lock"
          THEN /\ locked' = n.value
               /\ IF Mutation = "keepAcrossPause" THEN UNCHANGED <<epoch, reading>> ELSE Shut
               /\ UNCHANGED <<front, priv>>
          ELSE /\ front' = n.app /\ priv' = n.private
               /\ IF n.app # front \/ n.private # priv
                  THEN epoch' = epoch + 1 /\ reading' = 0
                  ELSE UNCHANGED <<epoch, reading>>
               /\ UNCHANGED locked
    /\ UNCHANGED <<wFront, wPrivate, wLocked, moves, running, paused, controls, giveups, reader, kept>>

\* `ask`: one read at a time, of the app believed to be in front, while the gate is open.
Ask ==
    /\ Open /\ Permitted
    /\ reading = 0 \/ Mutation = "manyReads"
    /\ reading' = epoch
    /\ asked' = asked \cup {[token |-> epoch, app |-> front]}
    /\ UNCHANGED <<world, running, paused, locked, front, priv, epoch, controls, giveups, results, losses, kept>>

\* .tick past `readTimeout`: stop waiting for a read that has not come back.  A read that is
\* gone for good can always be given up on; one that is merely slow, a bounded number of times
\* (the timeout is long next to a read, and the bound keeps the model finite).
Gone == reading # 0 /\ ~(\E q \in asked : q.token = reading) /\ ~(\E r \in results : r.token = reading)
GiveUp ==
    /\ reading # 0 /\ Mutation # "noTimeout"
    /\ Gone \/ giveups > 0
    /\ giveups' = IF Gone THEN giveups ELSE giveups - 1
    /\ reading' = 0 /\ epoch' = epoch + 1
    /\ UNCHANGED <<world, running, paused, locked, front, priv, controls, reader, kept>>

\* .read(token, reading): judged by what the reading actually is.
Return(r) ==
    /\ r \in results
    /\ results' = results \ {r}
    /\ IF reading = r.token
       THEN /\ IF /\ r.token = epoch /\ Open /\ r.app = front /\ r.app \notin Denied
                  /\ (~r.private \/ Mutation = "trustTheTitle")
               THEN /\ kept' = kept \cup {[app |-> r.fromApp, private |-> r.fromPrivate, readOpen |-> r.readOpen]}
                    /\ reading' = 0 /\ UNCHANGED <<epoch, priv>>
               ELSE IF r.token = epoch /\ Open /\ r.app = front /\ r.private
                    THEN \* a private window, found before its notification arrived
                         /\ priv' = TRUE /\ epoch' = epoch + 1 /\ reading' = 0 /\ UNCHANGED kept
                    ELSE reading' = 0 /\ UNCHANGED <<epoch, priv, kept>>
       ELSE UNCHANGED <<reading, epoch, priv, kept>>      \* not the read being waited for: dropped
    /\ UNCHANGED <<world, running, paused, locked, front, controls, giveups, asked, losses>>

(***************************************************************************)
(* The reader.  It reads the focused window of the app it was given, at    *)
(* the moment it runs, whatever has happened since it was asked, and       *)
(* reports that app and that window's title.  A reader that took a picture *)
(* of the whole screen instead would report the same thing, and hold       *)
(* whatever was really in front (the "wholeScreen" mutation).              *)
(***************************************************************************)
Perform(q) ==
    /\ q \in asked
    /\ asked' = asked \ {q}
    /\ LET source == IF Mutation = "wholeScreen" THEN wFront ELSE q.app IN
       results' = results \cup {[token |-> q.token, app |-> q.app, private |-> wPrivate[q.app],
                                 fromApp |-> source, fromPrivate |-> wPrivate[source], readOpen |-> Open]}
    /\ UNCHANGED <<world, running, paused, locked, front, priv, epoch, reading, controls, giveups, losses, kept>>

\* A read that never comes back (the app is hung, the window server does not answer).
Lose(q) ==
    /\ q \in asked /\ losses > 0
    /\ asked' = asked \ {q} /\ losses' = losses - 1
    /\ UNCHANGED <<world, running, paused, locked, front, priv, epoch, reading, controls, giveups, results, kept>>

Next ==
    \/ \E a \in Apps : SwitchApp(a)
    \/ TogglePrivate \/ ToggleLock
    \/ Start \/ Stop \/ Pause \/ Resume \/ Notice \/ Ask \/ GiveUp
    \/ \E q \in asked : Perform(q) \/ Lose(q)
    \/ \E r \in results : Return(r)

Fairness ==
    /\ WF_vars(Notice) /\ WF_vars(Ask) /\ WF_vars(GiveUp)
    \* Reads that are not lost are performed and returned.  Outstanding reads only shrink between
    \* asks, so fairness on "some read" is fairness on each.
    /\ WF_vars(\E q \in asked : Perform(q)) /\ WF_vars(\E r \in results : Return(r))

Spec == Init /\ [][Next]_vars /\ Fairness

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)
\* S1. Nothing from a denied app is ever kept.
NothingFromDeniedApps == \A k \in kept : k.app \notin Denied

\* S2. Nothing read from a (recognised) private window is ever kept.
NothingFromPrivateWindows == \A k \in kept : ~k.private

\* S3. Nothing that was read while capture was paused, locked or stopped is ever kept.
NothingReadWhileShut == \A k \in kept : k.readOpen

\* S4. At most one read that could still be kept is outstanding.
OneLiveRead == Cardinality({q \in asked : q.token = epoch} \cup {r \in results : r.token = epoch}) <= 1

\* S5. While the gate is shut, the reducer is not waiting for anything.
ShutMeansNotWaiting == ~Open => reading = 0

\* L1. Once the person settles in a permitted window with capture on, that window gets read and kept.
Settled == /\ moves = 0 /\ controls = 0 /\ losses = 0 /\ notes = <<>>
           /\ Open /\ wFront \notin Denied /\ ~wPrivate[wFront]
EventuallyRead == Settled ~> ([app |-> wFront, private |-> FALSE, readOpen |-> TRUE] \in kept)

(***************************************************************************)
(* Mutations.  With Mutation = "none" every property above holds.  Each    *)
(* other value removes one rule, and the property named must then fail:    *)
(*   wholeScreen      the reader takes the whole screen, and so holds      *)
(*                    whatever is in front, not the app it was given       *)
(*                                                     -> NothingFromDeniedApps *)
(*   trustTheTitle    a reading is judged by the last notified title,      *)
(*                    not its own                      -> NothingFromPrivateWindows *)
(*   keepAcrossPause  pause, lock and stop do not make earlier reads stale *)
(*                                                     -> NothingReadWhileShut *)
(*   manyReads        a new read may be asked for while one is out         *)
(*                                                     -> OneLiveRead      *)
(*   noTimeout        a read that never returns is waited for forever      *)
(*                                                     -> EventuallyRead   *)
(***************************************************************************)

\* Reachability: each is expected to be VIOLATED, which shows these states are reached.
NeverKept == kept = {}
NeverDropsAStaleRead == ~(\E r \in results : r.token # epoch)
NeverFindsAPrivateWindowByReading == ~(\E r \in results : r.token = epoch /\ r.private /\ ~priv /\ r.app = front)
=============================================================================

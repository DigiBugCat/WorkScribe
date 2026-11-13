---------------------------- MODULE IndexPurge ----------------------------
(***************************************************************************)
(* What the search index holds for one meeting while that meeting is       *)
(* purged, and afterwards.                                                 *)
(*                                                                         *)
(* Code: Sources/WorkScribe/IndexService.swift (purgeMeeting),             *)
(*       Sources/WorkScribeCore/Search/SearchIndexVectors.swift (purge),   *)
(*       Sources/WorkScribeCore/Engine/Index.swift (apply, its fence check)*)
(*       Sources/WorkScribe/MeetingRetention.swift (done),                 *)
(*       Sources/WorkScribeCore/Retention.swift (RetentionStore.purge),    *)
(*       Sources/WorkScribeCore/Ask/AttachmentIndexer.swift (index, prune).*)
(*                                                                         *)
(* A purge deletes a meeting's rows and sets fences ("purged:<ref>" and    *)
(* "purged:<root>" in the index's meta table) so that nothing of it can be *)
(* indexed again.  Indexing runs at the same time, off the actor that      *)
(* purges: an attachment being read when Done is pressed is applied        *)
(* whenever its text is ready.  Each `apply` is one SQLite transaction     *)
(* that checks the fences and inserts; each statement of the purge is its  *)
(* own step unless the code puts them in one transaction.                  *)
(*                                                                         *)
(* All fix constants FALSE is the code as it was found.                    *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Files,          \* attachments of the meeting: file sources whose root is the meeting's
    Convs,          \* conversations scoped to the meeting; each has one attachment of its own
    MaxBlocks,      \* how many times another connection may take hold of the write-ahead log
    MaxCrashes,     \* how many times the app may die in the middle of a purge
    Relaunch,       \* environment: the app is launched again after the purge (attachments are pruned)

    \* Fixes as written.
    FenceFirst,         \* the fences are set before what to delete is listed (one transaction in the code)
    RootsRechecked,     \* before the files go, conversations created since the last index purge are purged too
    CheckpointChecked,  \* a checkpoint another connection blocked fails the purge instead of passing for success

    \* Mutations: a deliberately broken variant, to show a passing property can fail.
    MutNoFences,              \* the purge sets no fences
    MutApplyIgnoresRootFence  \* apply checks only the source's own fence, not its root's

VARIABLES
    attached,   \* files of the meeting that exist (until its folder is removed)
    convs,      \* conversations scoped to the meeting that exist
    rows,       \* sources with rows in the index: "meeting", files, conversations (their attachment)
    rootFence,  \* the fences of the meeting and of its own attachment root are set
    convFence,  \* conversations whose attachment root is fenced
    refFence,   \* sources fenced by their own ref
    roots,      \* the conversations this pass of the purge knows about
    listed,     \* what this pass found to delete
    ipc,        \* the indexer of each file and of each conversation's attachment
    ppc,        \* the purge
    folder,     \* the meeting's folder exists
    gone,       \* conversations the purge deleted from disk
    residue,    \* deleted text is still in the index's files
    reader,     \* another connection holds the write-ahead log
    blocks, crashes, launched

vars == <<attached, convs, rows, rootFence, convFence, refFence, roots, listed, ipc, ppc, folder, gone,
          residue, reader, blocks, crashes, launched>>

Sources == Files \cup Convs
Meeting == "meeting"

TypeOK ==
    /\ attached \subseteq Files /\ convs \subseteq Convs /\ gone \subseteq Convs
    /\ rows \subseteq (Sources \cup {Meeting})
    /\ rootFence \in BOOLEAN /\ convFence \subseteq Convs /\ refFence \subseteq Sources
    /\ roots \subseteq Convs /\ listed \subseteq Sources
    /\ ipc \in [Sources -> {"idle", "queued", "read", "applied", "done"}]
    /\ ppc \in {"idle", "start", "listed", "fenced", "ready", "deleted", "indexed", "failed", "done"}
    /\ folder \in BOOLEAN /\ residue \in BOOLEAN /\ reader \in BOOLEAN /\ launched \in BOOLEAN
    /\ blocks \in 0..MaxBlocks /\ crashes \in 0..MaxCrashes

Init ==
    /\ attached = {} /\ convs = {} /\ rows = {Meeting}
    /\ rootFence = FALSE /\ convFence = {} /\ refFence = {}
    /\ roots = {} /\ listed = {}
    /\ ipc = [s \in Sources |-> "idle"]
    /\ ppc = "idle" /\ folder = TRUE /\ gone = {}
    /\ residue = FALSE /\ reader = FALSE /\ blocks = 0 /\ crashes = 0 /\ launched = FALSE

(***************************************************************************)
(* The person, and the indexer.                                            *)
(***************************************************************************)

\* AskService.files(_:) refuses a meeting whose copy in memory says "purging" or "purged".  `done` only
\* changes that copy at its very end, so until then a file can still be attached.
Attach(f) ==
    /\ f \in Files /\ f \notin attached /\ ipc[f] = "idle"
    /\ folder /\ ppc # "done" /\ ~launched
    /\ attached' = attached \cup {f}
    /\ ipc' = [ipc EXCEPT ![f] = "queued"]
    /\ UNCHANGED <<convs, rows, rootFence, convFence, refFence, roots, listed, ppc, folder, gone, residue, reader, blocks, crashes, launched>>

\* A question asked from the meeting's page starts a conversation scoped to it, with something attached.
\* Nothing stops that while the meeting is being purged: `done` cancels the answers in flight, not new ones.
Converse(c) ==
    /\ c \in Convs /\ c \notin convs /\ c \notin gone /\ ipc[c] = "idle"
    /\ ppc # "done" /\ ~launched
    /\ convs' = convs \cup {c}
    /\ ipc' = [ipc EXCEPT ![c] = "queued"]
    /\ UNCHANGED <<attached, rows, rootFence, convFence, refFence, roots, listed, ppc, folder, gone, residue, reader, blocks, crashes, launched>>

Exists(s) == IF s \in Files THEN s \in attached /\ folder ELSE s \in convs

\* The extractor reads the file.  One that has been deleted cannot be read.
Read(s) ==
    /\ ipc[s] = "queued"
    /\ ipc' = [ipc EXCEPT ![s] = IF Exists(s) THEN "read" ELSE "done"]
    /\ UNCHANGED <<attached, convs, rows, rootFence, convFence, refFence, roots, listed, ppc, folder, gone, residue, reader, blocks, crashes, launched>>

Fenced(s) ==
    \/ s \in refFence
    \/ ~MutApplyIgnoresRootFence /\ (IF s \in Files THEN rootFence ELSE s \in convFence)

\* SearchIndex.apply: one transaction.  The words are in memory by now; the file may be gone.
Apply(s) ==
    /\ ipc[s] = "read"
    /\ rows' = IF Fenced(s) THEN rows ELSE rows \cup {s}
    /\ ipc' = [ipc EXCEPT ![s] = "applied"]
    /\ UNCHANGED <<attached, convs, rootFence, convFence, refFence, roots, listed, ppc, folder, gone, residue, reader, blocks, crashes, launched>>

\* The vectors follow (writeVectors refuses a fenced source in its own SQL; it adds no rows either way).
Embed(s) ==
    /\ ipc[s] = "applied"
    /\ ipc' = [ipc EXCEPT ![s] = "done"]
    /\ UNCHANGED <<attached, convs, rows, rootFence, convFence, refFence, roots, listed, ppc, folder, gone, residue, reader, blocks, crashes, launched>>

(***************************************************************************)
(* The purge: MeetingRetention.done from the point where the journal says  *)
(* "purging".                                                              *)
(***************************************************************************)

\* The receipt is journalled with the conversations scoped to the meeting at this moment.
Begin ==
    /\ ppc = "idle"
    /\ ppc' = "start" /\ roots' = convs
    /\ UNCHANGED <<attached, convs, rows, rootFence, convFence, refFence, listed, ipc, folder, gone, residue, reader, blocks, crashes, launched>>

SetFences ==
    /\ rootFence' = (rootFence \/ ~MutNoFences)
    /\ convFence' = IF MutNoFences THEN convFence ELSE convFence \cup roots

List == listed' = {s \in rows \ {Meeting} : s \in Files \/ s \in roots}

\* As found: IndexService.purgeMeeting lists (two queries), then sets the fences (one statement each).
ListThenFence_List ==
    /\ ~FenceFirst /\ ppc = "start"
    /\ List /\ ppc' = "listed"
    /\ UNCHANGED <<attached, convs, rows, rootFence, convFence, refFence, roots, ipc, folder, gone, residue, reader, blocks, crashes, launched>>
ListThenFence_Fence ==
    /\ ~FenceFirst /\ ppc = "listed"
    /\ SetFences /\ ppc' = "ready"
    /\ UNCHANGED <<attached, convs, rows, refFence, roots, listed, ipc, folder, gone, residue, reader, blocks, crashes, launched>>

\* As fixed: fences, listing and deletion are one transaction.
Delete(what) ==
    /\ rows' = rows \ (what \cup {Meeting})
    /\ refFence' = IF MutNoFences THEN refFence ELSE refFence \cup what
    /\ residue' = TRUE          \* the old pages are in the files until a checkpoint and a vacuum complete
FenceListDelete ==
    /\ FenceFirst /\ ppc = "start"
    /\ SetFences
    /\ LET found == {s \in rows \ {Meeting} : s \in Files \/ s \in roots}
       IN listed' = found /\ Delete(found)
    /\ ppc' = "deleted"
    /\ UNCHANGED <<attached, convs, roots, ipc, folder, gone, reader, blocks, crashes, launched>>
DeleteListed ==
    /\ ~FenceFirst /\ ppc = "ready"
    /\ Delete(listed) /\ ppc' = "deleted"
    /\ UNCHANGED <<attached, convs, rootFence, convFence, roots, listed, ipc, folder, gone, reader, blocks, crashes, launched>>

\* PRAGMA wal_checkpoint(TRUNCATE), VACUUM, checkpoint again.  A connection in another process (the MCP
\* server reads the same index) that holds the log makes the checkpoint report "busy" instead of failing.
Checkpoint ==
    /\ ppc = "deleted"
    /\ IF ~reader THEN residue' = FALSE /\ ppc' = "indexed"
       ELSE /\ UNCHANGED residue
            /\ ppc' = IF CheckpointChecked THEN "failed" ELSE "indexed"
    /\ UNCHANGED <<attached, convs, rows, rootFence, convFence, refFence, roots, listed, ipc, folder, gone, reader, blocks, crashes, launched>>

\* A failed purge leaves the journal at "purging"; the retention loop runs `done` again a minute later.
Retry ==
    /\ ppc = "failed"
    /\ ppc' = "start" /\ roots' = roots \cup convs /\ listed' = {}
    /\ UNCHANGED <<attached, convs, rows, rootFence, convFence, refFence, ipc, folder, gone, residue, reader, blocks, crashes, launched>>

\* As fixed: conversations created while the index was being purged are purged too, before any file goes.
Recheck ==
    /\ RootsRechecked /\ ppc = "indexed" /\ ~(convs \subseteq roots)
    /\ ppc' = "start" /\ roots' = roots \cup convs /\ listed' = {}
    /\ UNCHANGED <<attached, convs, rows, rootFence, convFence, refFence, ipc, folder, gone, residue, reader, blocks, crashes, launched>>

\* RetentionStore.purge: every conversation scoped to the meeting now, and the meeting's folder, are
\* removed; the journal says "purged".  Nothing suspends between the recheck and this.
RemoveFiles ==
    /\ ppc = "indexed"
    /\ RootsRechecked => convs \subseteq roots
    /\ gone' = gone \cup convs /\ convs' = {}
    /\ folder' = FALSE /\ ppc' = "done"
    /\ UNCHANGED <<attached, rows, rootFence, convFence, refFence, roots, listed, ipc, residue, reader, blocks, crashes, launched>>

(***************************************************************************)
(* The environment.                                                        *)
(***************************************************************************)

ReaderBegins ==
    /\ ~reader /\ blocks < MaxBlocks
    /\ reader' = TRUE /\ blocks' = blocks + 1
    /\ UNCHANGED <<attached, convs, rows, rootFence, convFence, refFence, roots, listed, ipc, ppc, folder, gone, residue, crashes, launched>>
ReaderEnds ==
    /\ reader /\ reader' = FALSE
    /\ UNCHANGED <<attached, convs, rows, rootFence, convFence, refFence, roots, listed, ipc, ppc, folder, gone, residue, blocks, crashes, launched>>

\* Attachment sources whose file is gone are dropped at launch (AttachmentIndexer.prune).  That is an
\* ordinary delete: no vacuum, no checkpoint.
Pruned == {s \in rows \ {Meeting} : ~Exists(s)}

\* The app dies in the middle.  Work in flight is lost; the journal still says "purging", so the purge is
\* run again from the top after launch.
Crash ==
    /\ ppc \in {"start", "listed", "fenced", "ready", "deleted", "indexed", "failed"} /\ crashes < MaxCrashes
    /\ crashes' = crashes + 1
    /\ ipc' = [s \in Sources |-> IF ipc[s] = "idle" THEN "idle" ELSE "done"]
    /\ rows' = rows \ Pruned
    /\ residue' = (residue \/ Pruned # {})
    /\ ppc' = "start" /\ roots' = roots \cup convs /\ listed' = {}
    /\ UNCHANGED <<attached, convs, rootFence, convFence, refFence, folder, gone, reader, blocks, launched>>

Launch ==
    /\ Relaunch /\ ppc = "done" /\ ~launched
    /\ launched' = TRUE
    /\ ipc' = [s \in Sources |-> IF ipc[s] = "idle" THEN "idle" ELSE "done"]
    /\ rows' = rows \ Pruned
    /\ residue' = (residue \/ Pruned # {})
    /\ UNCHANGED <<attached, convs, rootFence, convFence, refFence, roots, listed, ppc, folder, gone, reader, blocks, crashes>>

PurgeStep == Begin \/ ListThenFence_List \/ ListThenFence_Fence \/ FenceListDelete \/ DeleteListed
                \/ Checkpoint \/ Retry \/ Recheck \/ RemoveFiles

Next ==
    \/ \E f \in Files : Attach(f)
    \/ \E c \in Convs : Converse(c)
    \/ \E s \in Sources : Read(s) \/ Apply(s) \/ Embed(s)
    \/ PurgeStep \/ ReaderBegins \/ ReaderEnds \/ Crash \/ Launch

Spec == Init /\ [][Next]_vars
\* The purge keeps going, the other connection lets go of the log, and no conversation is started forever.
Live == Spec /\ WF_vars(PurgeStep) /\ WF_vars(ReaderEnds)

(***************************************************************************)
(* Properties.                                                             *)
(***************************************************************************)

\* Once the journal says "purged", the index holds nothing of the meeting: not its transcript, not its
\* attachments, not the attachments of the conversations that were deleted with it.  Checked in every
\* later state too, so it also says nothing comes back.
Gone == ppc = "done" => rows \cap ({Meeting} \cup Files \cup gone) = {}

\* ... and none of the deleted text is left in the index's files.
NothingLeftOnDisk == ppc = "done" => ~residue

\* What the code as found does get right: whatever survived the purge is dropped at the next launch.
HealedByLaunch == launched => rows \cap ({Meeting} \cup Files \cup gone) = {}

\* The purge finishes.
PurgeEnds == (ppc = "start") ~> (ppc = "done")

=============================================================================

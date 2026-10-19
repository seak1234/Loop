# Cycle notes and Nightscout

Enable **Cycle → tap a calendar day → Cycle journal settings → Sync cycle notes with Nightscout**. Sync starts off, independently of Mochi permissions and daily-record retention. Enabling it shares existing and new journal notes with the configured Nightscout site. Treatment viewers can see the shared notes. The connection needs treatment read/create/update/delete permissions.

All integration lives in Loop. Nightscout's server and the existing NightscoutService module need no changes. The app uses the existing Nightscout connection, with its credentials kept out of journal state and AI context.

## What syncs

Each note carries its text, timestamp, tags, time zone, cycle day, phase, day within that phase, and whether its cycle timing is estimated or logged/reported. Both directions support new notes, edits, and deletions. Cycle context appears on note cards and can be edited in the app's note editor.

Cycle context is a saved snapshot attached to the note. New app notes use the tracker's calendar values for the selected day. Notes missing a cycle day, phase or phase day use the same calendar context as the tracker, even while a period end or the next period is awaiting confirmation. Missing context is repaired locally and included in sync. Unknown is used when history cannot place that note date. Saved values, including user edits, stay attached to their notes; **Use cycle tracker values** refreshes a note explicitly. Moving a note to a different date in the app refreshes its context. Changing its timestamp in Nightscout preserves its explicit context until that context is also edited.

Cycle day follows the same projected-cycle calculation as the cycle calendar. Phase day starts at 1 at each of the calendar's phase boundaries. Calendar-derived follicular, ovulation and luteal phases, and projected periods, are labeled estimated. These are calendar estimates, not measured hormone levels or confirmed ovulation. Editing note context does not edit period history.

## Adding or editing a note in Nightscout

Create an ordinary **Note** starting with `[Cycle]`, for example `[Cycle] Cramps after lunch`. The app imports it and supplies available cycle context. Other Nightscout notes and treatments are excluded.

Uploaded notes have a readable footer:

```text
[Cycle] Cramps after lunch

Cycle tags: cramps, sleep
Cycle time zone: America/Detroit
Cycle day: 20
Cycle phase: luteal
Phase day: 5
Cycle timing: estimated
```

Keep the `[Cycle]` prefix. Edit the footer to update the corresponding app fields. Tags use the journal's tag names (`sensitive`, `resistant`, `highs`, `lows`, `variable`, `cravings`, `sleep`, `stress`, `exercise`, `illness`, `cramps`). An empty tag list is allowed when text is supplied. A note may also contain only tags: leave the text blank and select at least one tag. Tag-only notes sync without adding invented text. Use `period`, `follicular`, `ovulation`, or `luteal` for phase; use `unknown` for an unknown phase or day. Days must be positive integers up to 10,000; phase day cannot exceed cycle day when both are supplied. A phase day requires a phase. Timing accepts `estimated` or `reported`. The time zone uses an IANA identifier, such as `America/Detroit`.

Preserve the footer labels and line breaks. Invalid marked notes pause syncing with an explanation. Removing the prefix from an already linked record also pauses syncing rather than interpreting it as a deletion. Notes with insulin or carb amounts are rejected by this integration.

## Sync behavior

Local changes queue durably in the journal and retry when the app is active. Sync checks on foreground/data refresh, about every five minutes while active, and after local note changes. The visible cycle screen checks periodically; **Sync now** requests an immediate attempt. iOS suspension stops this foreground workflow.

Turning sync off keeps both copies and their saved links. Re-enabling reconciles changes made while paused, including deletions. Changing the Nightscout site pauses note sharing until sync is explicitly turned off and on for that site.

Each site has its own ID mapping and last-synced content. Creates use a stable Mongo ObjectId persisted before the request, allowing a lost response or app restart to retry without duplicates. Writes are read back before being acknowledged. Discovery uses validated ObjectId cursor pagination with no recent-date cutoff. A known note is considered remotely deleted only after a successful exact-ID query, never because it is absent from a list. Incomplete or failed reads do not imply deletion.

When both copies changed relative to the last synchronized version, the app preserves the remote version and creates a separate local copy for the local edit. The copy uploads on the next pass. If a deletion conflicts with an edit, the edited content survives. A persistent notice invites review. This includes changes only to cycle context.

Nightscout's v1 API has no atomic compare-and-swap for treatment updates. Changes detected before a write are reconciled, but another client can still edit in the short interval between the final read and the write/delete. This integration cannot guarantee preservation of an intervening write in that interval without additional server support.

## Verification

`Scripts/test-cycle-note-sync.sh` executes the production client/reconciler and compiles the controller's integration methods against narrow service stubs. It covers both sync directions, multi-device behavior, context fields and phase boundaries, conflicts, offline retries, lost responses, permissions, consent changes, pagination, read-back verification, and legacy journals. It uses an in-memory HTTP transport and never contacts the user's Nightscout site.

`Scripts/test-cycle-companion.sh` covers existing cycle/journal behavior. `Scripts/typecheck-cycle-ui.sh` checks the actual SwiftUI screens with Mac Catalyst interfaces. A full iOS build and live-site/device verification still require Xcode and a configured test site. The SDK used by the compiler must match the installed Swift toolchain; `MOCHI_TEST_SDK` selects an alternative installed SDK.

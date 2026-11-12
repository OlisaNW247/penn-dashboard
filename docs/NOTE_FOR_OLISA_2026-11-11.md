# Note for Olisa: what v11 changed in the sync, and one licence question

2026-11-11. Written for Marco to send; nothing here needs an answer before
3.5.0 ships, but the last two sections want your eye.

## Server, deployed

- **`sync` v25** (2026-11-10, Marco's go): a phone report that lists no
  `file` ids can no longer retire a course's `file` rows
  (`liveIDsRetirableBy`). Without it the phone's hourly report would have
  deleted every PDF the extension pooled, and every PDF the phone itself now
  pools (below). v24 underneath it was deployed by someone without a note in
  CLAUDE.md on 2026-11-06; if that was you, say what it carried so the record
  is right.
- **`delete-account` v15** (2026-11-11): account deletion and Canvas
  disconnect now also remove the agent connection's draft files and staged
  uploads from Storage. The shared code is in `_shared/db.ts`, which `sync`
  bundles too, so the next `sync` deploy carries it.

## Phone, in `v11`

- **The course-material sync is held in an `AppState` task**
  (`pendingCourseKnowledgeSync`, `AppState+CourseKnowledge.swift`) instead of
  `ContentView`'s `.task`. SwiftUI cancelled that task on scene changes, which
  cancelled the URLSession request mid-manifest and read as `manifest failed`
  for a week on Marco's phone while the server logged 200. The summary line
  now names the cause: `manifest failed (cancelled | transport | http N |
  decoding (<path>))`. Proven on his phone 2026-11-10: `manifest ok ·
  uploaded 45` on the first open.
- **A new pass after a successful sync, `attachmentPass`**
  (`AppState+AssignmentAttachments.swift`, `AssignmentAttachmentPlanner`,
  `CanvasFilesClient`, `AssignmentAttachmentRunner`): reads the Canvas file
  ids linked from open and just-past assignment descriptions, fetches PDFs
  under 10 MB with the student's session, and uploads them as `file`
  documents, the shape your extension makes. Student uploads and submissions
  are never read. First real run the same day: `planned 9 · fetched 9 ·
  pooled 8 · skipped 1` for PHYS 0151. Disconnecting Canvas clears its memory
  (`attachmentAttemptsV1`, `lastAttachmentSyncSummaryV1`).
- **2026-11-04, earlier:** the pooled assignment text lost its `Status:
  submitted | not submitted` line, which put one student's submission state
  in every classmate's copy. Documents already pooled keep the old text until
  their next revision.

## The question for you: two collectors, one PDF

The phone reads a PDF's text with PDFKit (first 20 pages); the extension reads
it with pdf.js. Nobody has compared the two on the same file, so a PDF both
collect may hash differently and sit in the pool twice. If you have a course
where both run, a count of `file` rows per (course, url) would say.

## Unrelated, found by the font research the same day

The bundled Roobert files (`LowHangingFruitUI/Resources/Roobert-SemiBold.otf`
and the italic) are Displaay's **trial** build: PostScript name
`RoobertTRIAL-SemiBold`, and `RedesignTokens.swift` asks for that name.
Displaay's licence says trial fonts are not for public-facing projects. They
have been in every App Store build. CLAUDE.md records that you hold a
personal agreement for Roobert; if it covers this file, nothing to do. If it
was a licence for the full font, the licensed file should replace the trial
one before the next archive, and `lhfWordmark` / `lhfHeaderTitle` take the
new PostScript name. Details: `docs/FONT_RESEARCH_2026-11-11.md`, "Licence
note".

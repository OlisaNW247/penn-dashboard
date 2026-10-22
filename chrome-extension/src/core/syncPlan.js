// Port of Knowledge/SyncPlanner.swift (plan, uploads, uploadBatches), over
// wire documents rather than CourseDocument. Nothing here touches the network;
// the adapter calls these around the `sync` round trips (backend/PROTOCOL.md,
// "sync").
//
// Not ported: applyDownloads / applyCatalog / applyProfiles. They fold the
// server's answer into the phone's CourseKnowledgeBase, which the extension
// does not keep.

// Swift compares Strings by Unicode scalar; JavaScript's `<` by UTF-16 unit.
// They differ only for astral characters, but ids are sorted for byte-stable
// requests, so compare by code point.
function compareCodePoints(a, b) {
  const ca = Array.from(a);
  const cb = Array.from(b);
  const n = Math.min(ca.length, cb.length);
  for (let i = 0; i < n; i++) {
    const d = ca[i].codePointAt(0) - cb[i].codePointAt(0);
    if (d !== 0) return d;
  }
  return ca.length - cb.length;
}

// SyncPlanner.plan: which courses the server already holds a fresh full sync
// of (skip the Canvas fetch) and which still need one, in the caller's order.
// Announcements are fetched for every course regardless, per the protocol.
export function plan(courses, manifest) {
  const fresh = new Set(manifest.coursesFresh ?? []);
  return {
    coursesToFetch: courses.filter((c) => !fresh.has(c.courseID)),
    coursesFresh: fresh,
  };
}

// SyncPlanner.uploads: only documents the server does not already hold
// byte for byte (matched on id AND contentHash, so an edited document
// re-uploads), sorted by id; plus one fullySyncedCourses entry per fully
// fetched course, listing every document id the client now holds for it
// (sorted), so the server can mark vanished documents gone for exactly those
// courses.
//   local           CourseDocumentWire[]  everything the client holds
//   serverManifest  DocumentStub[]        the manifest answer's serverManifest
//   fullyFetched    Iterable<courseID>
//   links           CourseLinkWire[]      forwarded unfiltered
//   client          optional "extension"  the `client` field of the upload
//                                         (backend/PROTOCOL.md); omitted when unset
export function uploads({ local, serverManifest, fullyFetched, links = [], client }) {
  const known = new Set(serverManifest.map((s) => `${s.id}\u0000${s.contentHash}`));
  const documents = local
    .filter((d) => !known.has(`${d.id}\u0000${d.contentHash}`))
    .sort((a, b) => compareCodePoints(a.id, b.id));
  const fullySyncedCourses = [...fullyFetched]
    .sort(compareCodePoints)
    .map((courseID) => ({
      courseID,
      documentIDs: local.filter((d) => d.courseID === courseID).map((d) => d.id).sort(compareCodePoints),
    }));
  const request = { action: "upload", documents, fullySyncedCourses, links };
  if (client !== undefined) request.client = client;
  return request;
}

// The protocol's body cap. The phone only counts documents (200 per batch, a
// "conservative stand-in"); the extension's file documents can be 60,000
// characters each, so it also counts bytes.
export const MAX_BATCH_DOCUMENTS = 200;
export const MAX_BODY_BYTES = 6 * 1024 * 1024;

const encoder = new TextEncoder();
function bodyBytes(request) {
  return encoder.encode(JSON.stringify(request)).length;
}

// SyncPlanner.uploadBatches: splits an upload into batches of at most
// `maxDocuments` documents AND (new) whose JSON body stays under `maxBytes`.
// `fullySyncedCourses` and `links` ride only on the LAST batch: the server
// marks a fully-synced course's vanished documents gone, which is only true
// once every live document has arrived. With no documents there is still one
// batch (a course with zero documents is still fully synced).
//
// A document that alone exceeds `maxBytes` is sent alone, not dropped (the
// server will refuse it; hiding it here would hide the reason). If the last
// batch plus the trailer would exceed `maxBytes`, the trailer goes in a final
// batch of its own with no documents, so `fullySyncedCourses` still arrives
// strictly after every document.
export function uploadBatches(request, { maxDocuments = MAX_BATCH_DOCUMENTS, maxBytes = MAX_BODY_BYTES } = {}) {
  const base = { action: "upload" };
  if (request.client !== undefined) base.client = request.client;
  const make = (documents, last) => ({
    ...base,
    documents,
    fullySyncedCourses: last ? request.fullySyncedCourses : [],
    links: last ? request.links : [],
  });

  if (request.documents.length === 0) return [make([], true)];

  const limit = Math.max(maxDocuments, 1);
  const overhead = bodyBytes(make([], false));
  const trailer = bodyBytes(make([], true)) - overhead;
  const chunks = [];
  let current = [];
  let size = overhead;
  for (const doc of request.documents) {
    const docBytes = encoder.encode(JSON.stringify(doc)).length + 1; // + the comma
    if (current.length > 0 && (current.length + 1 > limit || size + docBytes > maxBytes)) {
      chunks.push({ docs: current, size });
      current = [];
      size = overhead;
    }
    current.push(doc);
    size += docBytes;
  }
  chunks.push({ docs: current, size });

  const batches = chunks.map((c, i) => make(c.docs, i === chunks.length - 1));
  const last = chunks[chunks.length - 1];
  if (last.size + trailer > maxBytes) {
    // The trailer would push the last batch over: it goes in a final batch of
    // its own, still strictly after every document.
    batches[batches.length - 1] = make(last.docs, false);
    batches.push(make([], true));
  }
  return batches;
}

// CourseKnowledgeCollector.run: "a course counts as re-synced (so vanished
// documents are dropped) only when most of its endpoints answered": the phone
// allows ONE failed endpoint of four (`courseErrors <= 1`). That is
// PHONE_MAX_ENDPOINT_ERRORS. The extension's `client: "extension"` upload is
// authoritative for every collector's rows, so a half-failed course listed as
// fully synced would retire the phone's rows for the endpoint that failed;
// the default here is zero tolerated failures.
export const PHONE_MAX_ENDPOINT_ERRORS = 1;

// courseResults: { [courseID]: number of failed endpoints this run }
// Returns the set of course ids to pass as `fullyFetched`.
export function fullyFetchedCourseIDs(courseResults, { maxErrors = 0 } = {}) {
  const ids = new Set();
  const entries = courseResults instanceof Map ? [...courseResults] : Object.entries(courseResults);
  for (const [courseID, errors] of entries) if (errors <= maxErrors) ids.add(courseID);
  return ids;
}

import { test } from "node:test";
import assert from "node:assert/strict";
import { fnv1a, documentID, documentContentHash } from "../src/core/contentHash.js";

// No Swift test pins a hash value (checked: Tests/ only compares hashes with each
// other). These are the published FNV-1a 64-bit reference vectors, which is what
// ContentHash.fnv1a (CourseDocument.swift:336-345) implements, and were also
// recomputed with an independent Python implementation.
test("fnv1a matches the FNV-1a 64-bit reference vectors", () => {
  assert.equal(fnv1a(""), "cbf29ce484222325");
  assert.equal(fnv1a("a"), "af63dc4c8601ec8c");
  assert.equal(fnv1a("foobar"), "85944171f73967e8");
});

// No Swift test. Swift's String(hash, radix: 16) does not zero-pad; "aa" hashes
// to a value below 2^60, so it has 15 digits.
test("hex output is not zero-padded", () => {
  assert.equal(fnv1a("aa"), "89c4307b54596b7");
  assert.equal(fnv1a("aa").length, 15);
});

// No Swift test. The hash runs over UTF-8 bytes: U+00E9 is C3 A9.
test("hashes UTF-8 bytes", () => {
  assert.equal(fnv1a("é"), "ac21707b7181e01");
});

// CourseDocument.swift:46 and :93
test("documentID and documentContentHash", () => {
  assert.equal(documentID("syllabus", "123", "abc"), "syllabus:123:abc");
  assert.equal(documentContentHash("T", "body"), fnv1a("T\u001Fbody"));
  assert.notEqual(documentContentHash("ab", "c"), documentContentHash("a", "bc"));
});

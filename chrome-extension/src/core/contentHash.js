// Port of ContentHash.fnv1a (Models/CourseDocument.swift:336-345) and the two
// identity rules from CourseDocument. The phone and the extension must agree
// byte for byte, or each re-uploads the other's copy forever.

const OFFSET_BASIS = 0xcbf29ce484222325n;
const PRIME = 0x100000001b3n;
const MASK_64 = 0xffffffffffffffffn;
const UNIT_SEPARATOR = "\u001F";

// 64-bit FNV-1a over the UTF-8 bytes, lowercase hex with no zero padding,
// because Swift's `String(hash, radix: 16)` does not pad. A hash with leading
// zero nibbles is therefore shorter than 16 characters.
export function fnv1a(string) {
  let hash = OFFSET_BASIS;
  for (const byte of new TextEncoder().encode(string)) {
    hash ^= BigInt(byte);
    hash = (hash * PRIME) & MASK_64;
  }
  return hash.toString(16);
}

// CourseDocument.swift:46.
export function documentID(kind, courseID, sourceID) {
  return `${kind}:${courseID}:${sourceID}`;
}

// CourseDocument.swift:93. U+001F separates title from text so that
// ("ab", "c") and ("a", "bc") hash differently.
export function documentContentHash(title, text) {
  return fnv1a(title + UNIT_SEPARATOR + text);
}

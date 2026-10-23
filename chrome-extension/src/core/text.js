// Foundation's trimming sets, which JavaScript's String.trim() does not match:
// it also strips U+FEFF, and it leaves U+0085 (NEL) alone, which Swift's
// `.whitespacesAndNewlines` removes. The ICS feed carries stray CRs and
// trailing blanks routinely (CanvasICSClient.swift:96-116), so the exact set
// decides whether a class survives.

const WS_AND_NEWLINES = /^[\p{White_Space}]+|[\p{White_Space}]+$/gu;
// `CharacterSet.whitespaces` is Unicode Zs plus tab; it does not include
// newlines, so a bracketed course like "[\nCIS 1200]" keeps its newline.
const WS_ONLY = /^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu;

export function trimWhitespaceAndNewlines(s) {
  return s.replace(WS_AND_NEWLINES, "");
}

export function trimWhitespaces(s) {
  return s.replace(WS_ONLY, "");
}

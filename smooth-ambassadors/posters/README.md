# posters

The generic poster designs made in-house (2026-11-22), as opposed to Marco's
print masters, which are not in git because several carry photos of real
people.

- `src/` — one HTML file per design plus `poster.css`. Fonts and the S mark
  are read from the app's own bundled resources
  (`LowHangingFruitKit/Sources/LowHangingFruitUI/Resources`), so nothing is
  duplicated here. The page is 2376 × 3672 px, the size of Marco's masters
  (11 × 17 in at 216 dpi). Each design ends with a dashed square: the slot
  the QR sticker from the ambassador's stickers page goes in, so one print
  serves every school.
- `previews/` — the 700 px wide JPEGs the ambassador page, the app's gallery
  and `/posters/{school}/{key}.jpg` show. Committed, because the Sites build
  embeds them (`scripts/build-sites.mjs` adds any catalog design the live
  Worker does not have yet, for every school).
- `node scripts/render-posters.mjs` re-renders both from `src/` with the
  Google Chrome on this Mac (print PNGs land in `posters/print/`, which is
  git-ignored).

The keys are the catalog's (`worker/catalog.js`); a file name here must be a
`DESIGNS` entry.

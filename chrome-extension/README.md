# chrome-extension

The Smooth Chrome extension. So far only the pure core in `src/core/`: plain ES modules ported from the Swift parsing rules. Design: `docs/CHROME_EXTENSION.md`.

    cd chrome-extension && npm test

From the repo root: `TZ=America/New_York node --test "chrome-extension/test/*.test.js"`.

The extension shell (manifest, popup) and the load-unpacked steps come in a later step.

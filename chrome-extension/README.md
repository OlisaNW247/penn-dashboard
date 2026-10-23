# chrome-extension

The Smooth Chrome extension: a helper for the phone. Design: `docs/CHROME_EXTENSION.md`.

## Load it

1. `cd ~/lhf-app && git pull`
2. Chrome → `chrome://extensions` → turn on Developer mode.
3. Load unpacked → pick `~/lhf-app/chrome-extension`.
4. After a pull, press the reload arrow on the Smooth card.

The popup reads your Canvas and Gradescope work using the sessions Chrome already has. Sign in to both in the browser first.

## Test

    cd chrome-extension && npm test

From the repo root: `TZ=America/New_York node --test "chrome-extension/test/*.test.js"`.

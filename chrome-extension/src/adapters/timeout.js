// A fetch that cannot wait forever. The signal aborts a real fetch (headers and
// body); the race below also frees the caller when a fetch ignores the signal.
// A caller-supplied signal is respected and not replaced.
export async function fetchWithTimeout(fetchFn, url, init, ms) {
  const signal = init?.signal ?? AbortSignal.timeout(ms);
  const pending = fetchFn(url, { ...init, signal });
  let onAbort;
  const aborted = new Promise((_, reject) => {
    onAbort = () => reject(new Error("timeout"));
    if (signal.aborted) onAbort();
    else signal.addEventListener("abort", onAbort, { once: true });
  });
  try {
    return await Promise.race([pending, aborted]);
  } finally {
    signal.removeEventListener("abort", onAbort);
  }
}

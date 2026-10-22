// PDF text extraction with the vendored pdf.js (vendor/pdfjs/VERSION), in the
// calling thread. An MV3 module service worker cannot create a Worker or use
// dynamic import(), so the worker module is imported statically and
// registered as globalThis.pdfjsWorker; pdf.js then runs its "fake worker"
// path on the main thread. No network: no cMapUrl, no standardFontDataUrl,
// no eval, no font-face loading.
import { WorkerMessageHandler } from "../../vendor/pdfjs/pdf.worker.min.mjs";
import * as pdfjs from "../../vendor/pdfjs/pdf.min.mjs";

globalThis.pdfjsWorker = { WorkerMessageHandler };

// bytes: Uint8Array. Returns the text of every page, joined by newlines
// (page order), or "" when there is no text layer. Throws on a corrupt PDF.
export async function extractPdfText(bytes) {
  const task = pdfjs.getDocument({
    data: bytes,
    isEvalSupported: false,
    disableFontFace: true,
    useWorkerFetch: false,
    useSystemFonts: false,
    verbosity: 0,
  });
  const doc = await task.promise;
  try {
    const parts = [];
    for (let n = 1; n <= doc.numPages; n++) {
      const page = await doc.getPage(n);
      const content = await page.getTextContent();
      parts.push(content.items.map((i) => (typeof i.str === "string" ? i.str + (i.hasEOL ? "\n" : " ") : "")).join(""));
      page.cleanup();
    }
    return parts.join("\n");
  } finally {
    await doc.destroy();
  }
}

// Entry point. Ambassador routes first; everything else falls through to the
// legacy tracker untouched, so every printed /scan/... code keeps working.
import { handleAmbassadors } from "./ambassadors.js";
import legacy from "./legacy.js";

export default {
  async fetch(request, env, ctx) {
    const handled = await handleAmbassadors(request, env, ctx);
    if (handled) return handled;
    return legacy.fetch(request, env, ctx);
  },
};

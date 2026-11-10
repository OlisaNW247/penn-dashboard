// Text the founders send from their own phone. No automated texting.
import { SCHOOLS } from "./catalog.js";
import moments from "./templates/moments.json";

const ACTIONS = [
  "paste the group chat message into one new chat",
  "put up one poster somewhere people actually wait in line",
  "send us one thing that's broken or annoying in the app",
  "post once on fizz or sidechat",
  "send the dm follow-up to one friend who said 'oh that's cool'",
];

function fill(t, vars) {
  return t.replace(/\{(\w+)\}/g, (_, k) => (vars[k] ?? `{${k}}`));
}

export function firstName(name) {
  return (name || "").trim().split(/\s+/)[0] || "hey";
}

// The page link carries the secret token; everything that gets posted, texted
// to friends or printed carries only the public ref, so seeing a post never
// reveals the private page.
export function ambassadorLinks(origin, amb) {
  return {
    page: `${origin}/a/${amb.token}`,
    gc: `${origin}/r/${amb.ref}/s/gc`,
    share: (ch) => `${origin}/r/${amb.ref}/s/${ch}`,
    poster: (design) => `${origin}/r/${amb.ref}/p/${design}`,
  };
}

// Two-week digest for one ambassador, built from real numbers.
export function digestText({ amb, origin, leaderboard, week = 0, newPoster = null }) {
  const links = ambassadorLinks(origin, amb);
  const school = SCHOOLS[amb.school]?.name ?? amb.school;
  const me = leaderboard.schools.find((s) => s.school === amb.school);
  const ahead = leaderboard.schools.find((s) => s.rank === (me?.rank ?? 1) - 1);
  const behind = leaderboard.schools.find((s) => s.rank === (me?.rank ?? 1) + 1);
  const score = (s) => (s ? s.recent + s.linkOpensRecent : 0);

  const parts = [];
  parts.push(`hey ${firstName(amb.name)}, quick smooth update, no reply needed.`);
  const mine = amb.linkOpensRecent + amb.posterOpensRecent;
  if (mine > 0) parts.push(`your links got ${mine} open${mine === 1 ? "" : "s"} in the last 2 weeks.`);
  if (me) {
    let standing = `${school.toLowerCase()} posters: ${me.recent} scans in 2 weeks (${me.total} all-time).`;
    const n = leaderboard.schools.length;
    if (me.rank === 1 && behind) standing += ` on the 2-week board ${school.toLowerCase()} is #1, ${score(me) - score(behind)} ahead of ${behind.name.toLowerCase()}.`;
    else if (ahead) standing += ` on the 2-week board ${school.toLowerCase()} is #${me.rank} of ${n}, ${score(ahead) - score(me)} behind ${ahead.name.toLowerCase()}.`;
    parts.push(standing);
  }
  if (newPoster) parts.push(`new poster this week: ${newPoster}. it's on your page.`);
  parts.push(`if you have 30 seconds: ${ACTIONS[week % ACTIONS.length]}. everything's here: ${links.page}`);
  parts.push(`reply "pause" and i'll stop these for a while.`);
  return parts.join(" ");
}

export function welcomeText({ amb, origin }) {
  const links = ambassadorLinks(origin, amb);
  return [
    `hey ${firstName(amb.name)}! thanks for helping with smooth at ${(SCHOOLS[amb.school]?.name ?? amb.school).toLowerCase()}.`,
    `here's your page, it's private to you, no login: ${links.page}`,
    `it has the messages to copy, your school's posters, and your own numbers. the whole thing is 15 minutes if you want it to be.`,
    `if it ever feels like a chore, tell me and we'll dial it down. no pressure ever.`,
  ].join(" ");
}

export function momentTexts({ amb, origin, key }) {
  const m = moments.moments.find((x) => x.key === key);
  if (!m) return null;
  const links = ambassadorLinks(origin, amb);
  const vars = {
    name: firstName(amb.name),
    school: (SCHOOLS[amb.school]?.name ?? amb.school).toLowerCase(),
    link: links.gc,
    page: links.page,
  };
  return {
    key: m.key,
    label: m.label,
    when: m.when,
    toAmbassador: fill(m.to_ambassador, vars),
    forward: fill(m.forward, vars),
    combined: `${fill(m.to_ambassador, vars)}\n\n${fill(m.forward, vars)}`,
  };
}

export { moments };

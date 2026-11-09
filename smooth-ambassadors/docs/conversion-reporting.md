# download conversion reporting

**Status: researched and wired, waiting on one thing from Olisa or Marco.**

## what's needed

A campaign link created in App Store Connect for Smooth. That gives the
**provider token** (`pt`), which is the same for every campaign on the
account and cannot be created by hand. Steps (App Store Connect help,
"Campaign links", read 2026-11-09):

1. App Store Connect → Apps → Smooth → Analytics → Acquisition → Campaigns
   → "+". Name it anything (e.g. `test`). Copy the link; it looks like
   `https://apps.apple.com/app/apple-store/id6783911002?pt=123456&ct=test&mt=8`.
2. Set `APPLE_PROVIDER_TOKEN` to the `pt` value (a Worker variable, not
   secret-sensitive but keep it out of git anyway).

That is it. Redirects already carry campaign tokens when the variable is
set:

| Redirect | `ct` |
|---|---|
| `/scan/ib` | `ib` |
| `/scan/uva/soccer` | `uva-soccer` |
| `/a/{token}/p/soccer` (ambassador sticker) | `uva-soccer-a<id>` |
| `/a/{token}/s/gc` (share link) | `uva-<id>-gc` |

Tokens stay under Apple's 30-character limit and use only allowed
characters.

## apple's rules that shape the numbers (official page, 2026-11-09)

- "When a user downloads your app for the first time within **24 hours** of
  using your campaign link or campaign token, they're counted as a
  First-Time Download."
- "If a user clicks more than one campaign link within a given timeframe,
  only the most recent link receives credit."
- "Campaigns appear in Analytics only after a minimum of **24 hours** since
  their launch."
- "Each metric for your campaign will appear in the dashboard if the
  metric meets a minimum threshold of **5** in the date range selected."
- "Data for a particular campaign will appear in the dashboard once it has
  generated first-time downloads from at least **five individual users**."
- Rows for very small groups in the detailed reports "might be withheld or
  combined with other rows".

Consequences for a program of a few friends:
- per-ambassador campaign tokens will often sit under the threshold of 5
  and show nothing. Widen the date range, or read conversion at the
  school/design level and use ambassador *link opens* (which we count
  ourselves) as the leading indicator.
- a scan that leads to a download the next day isn't attributed.

## the formula

conversion = attributed first-time downloads ÷ link opens × 100, over the
same date range. Link opens come from `scan_events` and `amb_hits` (ours),
downloads from Apple's campaign report (export via App Store Connect or the
Analytics Reports API). Expect opens to be inflated by repeats and about
one test scan per new code, so treat it as a trend, not a truth.

## what to build once the token exists

- a small import: paste Apple's campaign CSV into the founder view (or a
  script in `scripts/`) → table `apple_campaign_daily(ct, date, first_time_downloads, product_page_views)`.
- a "conversion" section on the founder view by school and design, and by
  ambassador where the counts clear 5.

# Verifying the sign-out fix on two phones

Written 2026-10-09 for `v8` at or after `e118b95` (3.0.1 build 12, the
sign-out fix of `9728280`). This is the runbook for the one check that
nothing on a Mac can replace: the fix has only ever compiled. Everything
below runs on the dev Mac with a phone tethered. Paste the readings back
into the session that is driving the release; they are secret-free by
design, but read them before pasting and redact anything that looks like
a cookie value, a feed URL or a PennKey.

Why two phones: the investigation (`docs/SIGNOUT_INVESTIGATION.md`) found
that the same App Store build behaves differently with and without a saved
PennKey password and Duo trust. Phone A has both; phone B has neither.
A pass on one phone proves nothing about the other.

## Before starting

- Mac on `v8`, `swift test --no-parallel` green (1499 / 152 at `e118b95`).
- Both phones paired in Xcode → Devices and Simulators. Finder's "Trust"
  alone is not enough for `devicectl` to read a phone's containers.
- Confirm each phone's CoreDevice id (the one `devicectl` takes; it is not
  the Xcode UDID that `-showdestinations` prints):

```bash
xcrun devicectl list devices
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit -showdestinations 2>/dev/null | grep -i iphone
```

Phone A (Olisa's iPhone 17) is `C9A0CCE1-8C16-5BCC-A4D2-E84DC0EFCE04`. Its
App Store 3.0.0 (11) install could not be read by `devicectl`
(`ContainerLookupErrorDomain error 7`, apps not installed by Xcode). The
Debug install below replaces it in place, keeps the data container and the
Keychain, and makes the plist readable.

## Phone A: saved password and Duo trust

Expected outcome: a silent renewal with no banner, in the foreground and
then from a simulated background wake.

1. Build and install Debug, then launch with the aged session and the
   console attached (the `--` matters, or `devicectl` eats the flag):

```bash
xcodebuild -project LowHangingFruit.xcodeproj -scheme LowHangingFruit -configuration Debug \
  -destination 'id=<UDID of phone A>' -allowProvisioningUpdates build
xcrun devicectl device install app --device C9A0CCE1-8C16-5BCC-A4D2-E84DC0EFCE04 <DerivedData path>/Smooth.app
xcrun devicectl device process launch --console --terminate-existing \
  --device C9A0CCE1-8C16-5BCC-A4D2-E84DC0EFCE04 com.lhf.lowhangingfruit -- -LHFAgeCanvasSession
```

   Watch for `LHF-RENEW` lines. Pass: the last one reads `renewed`, no
   Duo prompt was pushed to the phone, and the dashboard shows no banner.
   The banner is driven by the 24-hour cookie rule, which flips before
   the renewal starts; the fix hides it while a renewal is in flight, so
   a banner that appears and stays is a failure, and one that flashes
   for the length of the renewal means that hiding did not work (note it,
   it is not a sign-out). Fail: a banner that stays ("your canvas login
   needs a refresh" or "duo needs you to sign in once"), or a Duo push.

2. Open Profile → accounts and copy the three lines under Canvas. Expected:
   - `pennkey password saved — smooth signs in for you`
   - `duo remembers this phone — penn asks again about every 30 days`
   - `last silent sign-in: signed in silently, <today's date and time> (foreground)`

3. Background wake. Run the app from Xcode (the debugger must be attached
   for the menu item to exist), press Home so the app is in the
   background, then Xcode → Debug → Simulate Background Fetch. Wait 30 s.
   Pass: the app is still running (no `SIGTRAP`; the first-ever background
   wake that does not crash). Then read the renewal keys off the phone:

```bash
xcrun devicectl device copy from --device C9A0CCE1-8C16-5BCC-A4D2-E84DC0EFCE04 \
  --domain-type appGroupDataContainer --domain-identifier group.com.lhf.lowhangingfruit \
  --source Library/Preferences/group.com.lhf.lowhangingfruit.plist --destination /tmp/lhf.plist
plutil -p /tmp/lhf.plist | grep -E 'debugRenewalLogV1|lastSilentRenewal|canvasSessionConfirmedDeadV1|autoLoginAwaitingDuoV1|lastCredentialSubmissionAtV1|silentRenewalConsecutiveLandingsV1' -A 3
```

   Expected after the simulated fetch:
   - `canvasSessionConfirmedDeadV1` false, `autoLoginAwaitingDuoV1` false
     (a background wake may only help, never latch).
   - `lastSilentRenewalSummaryV1` naming a `background` context. If the
     session was still fresh from step 1 the background pass may not
     renew at all; that is fine. To force it, relaunch with
     `-LHFAgeCanvasSession` from Xcode first, background immediately, then
     simulate the fetch.
   - `lastCredentialSubmissionAtV1` set to the step-1 time, and not
     advanced by the background wake if it was within six hours (the
     background path must not resubmit the password that soon).
   - `debugRenewalLogV1` entries for both the foreground and background
     attempts, each a time, app state and status, never a URL.

4. Crash check, which is what found the original background crash:

```bash
xcrun devicectl device info files --device C9A0CCE1-8C16-5BCC-A4D2-E84DC0EFCE04 --domain-type systemCrashLogs | grep Smooth
```

   Pass: no `Smooth-2026-10-09…ips`. If there is one, copy it with
   `device copy from --domain-type systemCrashLogs` and read the thread
   marked `"triggered": true`.

## Phone B: no saved password, no Duo trust

Samuel's iPhone 15, or any Penn phone that has never saved the PennKey
password. Pair it in Xcode first. Expected outcome: the banner (a
password-less phone cannot renew on its own), reconnect straight to the
Canvas login, trusted health lines after one interactive login, and, if
the password is then saved, a silent renewal on the next aged launch.

1. Install Debug and launch with `-LHFAgeCanvasSession` exactly as for
   phone A (its own CoreDevice id). With no password the renewal is a
   GET-only reload and should end on Penn's login page. Pass: the console
   ends `landed-on-login`, the banner `your canvas login needs a refresh`
   is showing (the aged cookie alone shows it; the two-landings rule only
   decides whether a cookie that still looks fresh is latched dead), and
   the health lines read `no pennkey password saved …`, `duo: not trusted
   yet …`, `last silent sign-in: landed on the login page, …`. No Duo push.

2. Read the plist (phone A, step 3, with this phone's id). Expected:
   `silentRenewalConsecutiveLandingsV1` 1, `canvasSessionConfirmedDeadV1`
   false, `autoLoginAwaitingDuoV1` false. Terminate, launch again with
   `-LHFAgeCanvasSession`, read again: landings 2 and dead true. That is
   the latch working as designed, and a second launch within the hour is
   allowed only because the flag clears the attempt cooldown.

3. Tap the banner. Pass: it opens the Canvas login pane directly, not the
   school picker. The back chevron from the login pane should reveal the
   picker; tapping a different school there must now ask before it signs
   you out (cancel it).

4. Sign in with PennKey. At Duo, answer **yes, this is my device**. On the
   PennKey sheet afterwards, save the password if Samuel agrees to be the
   week-long TestFlight tester; otherwise "not now" and note it.

5. Health lines now. Pass: `duo remembers this phone — penn asks again
   about every 30 days`, and if the password was saved, `pennkey password
   saved …`.
   Read the plist once more: landings 0, dead false, no stale outcome.

6. If the password was saved: launch once more with `-LHFAgeCanvasSession`.
   Pass: `renewed`, no Duo prompt, no banner. This is the state every
   affected student should end up in after 3.0.1.

7. Paste the console lines, health lines and plist grep for this phone.

## What to paste back

For each phone: the `LHF-RENEW` console lines, the three health lines
verbatim, the `plutil -p … | grep` output, and the crash-log listing. Say
which steps passed and which did not, in order. A failure on any step is a
code change on `v8` before the archive; do not archive 3.0.1 (12) with a
step failing.

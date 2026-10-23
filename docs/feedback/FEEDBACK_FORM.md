# Smooth feedback form

_Written 2026-10-22. The questions below are the Google Form for Smooth
users. `create-feedback-form.gs` beside this file builds the form in your
Google Drive in one run (see the steps at the end). Keep the register:
lowercase, short, the least text that works._

## Live form

Created in Olisa's Google account on 2026-10-22 with the script beside
this file. Public link, the one to hand to students:
https://docs.google.com/forms/d/e/1FAIpQLScZJ4BBXicAOFYSbCkHGcM5kWcDD8OXSSWtkK64kSSUO4WcJQ/viewform
The edit link and the responses sheet are in Olisa's Drive and are not
recorded here. Changing a question means editing it in Google Forms (the
live form) and here (the record); re-running the script makes a second
form, not an update.

## Title

**smooth feedback**

## Description

two minutes. nothing here is tied to your canvas account; the only thing
we keep is what you type.

## Questions

1. **what school are you at?** (short answer, required)
2. **what year?** (multiple choice, required): first year · sophomore ·
   junior · senior · grad · other
3. **how long have you used smooth?** (multiple choice, required): just
   installed · a few days · a few weeks · a month or more
4. **what's connected?** (checkboxes): canvas · gradescope · ed
   discussion · nothing yet
5. **how often do you open it?** (multiple choice): every day · a few
   times a week · once a week · rarely
6. **which parts do you actually use?** (checkboxes): the todo list ·
   reminders · the smooth sweeper (the 10-minute alarm) · ask / the tree ·
   the megaphone (announcements) · the widget · adding my own tasks
7. **how much do you trust the list to be complete?** (linear scale 1 to
   5, "missing things" to "everything's there")
8. **did the sweeper ever save you from missing a deadline?** (multiple
   choice): yes · not yet · i turned it off · didn't know it existed
9. **how good are the tree's answers?** (linear scale 1 to 5, "wrong or
   empty" to "spot on")
10. **what did it get wrong, or what couldn't it answer?** (paragraph)
11. **what's the one thing you wish smooth did?** (paragraph, required)
12. **anything broken or annoying?** (paragraph)
13. **would you tell a friend to install it?** (linear scale 0 to 10,
    "no" to "already did")
14. **email, only if you want a reply** (short answer, optional; response
    validation: email)

## Settings

- Collect email: off (question 14 is the opt-in instead).
- Limit to one response: off (no sign-in required, so students outside
  Penn's Google can answer).
- Confirmation message: "thanks. we read every one."
- Responses: link to a new sheet named "smooth feedback (responses)".

## How to create it

1. Open https://script.google.com and click **New project**.
2. Replace the editor's contents with `create-feedback-form.gs` from this
   folder, then click **Run** (the function is `createSmoothFeedbackForm`).
3. Approve the permission prompt once (Forms and Sheets, your own account).
4. Open **View → Logs** (or the execution log at the bottom): it prints the
   form's edit URL and the public link.
5. Share the public link. The responses sheet is in your Drive beside the
   form.

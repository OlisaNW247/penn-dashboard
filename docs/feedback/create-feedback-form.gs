/**
 * Builds the "smooth feedback" Google Form in the account that runs it.
 * Run once from script.google.com (New project → paste → Run). The form's
 * questions are the ones in FEEDBACK_FORM.md; edit there first, then here.
 * Logs the edit URL and the public link when done.
 */
function createSmoothFeedbackForm() {
  var form = FormApp.create("smooth feedback");
  form.setDescription(
    "two minutes. nothing here is tied to your canvas account; the only thing we keep is what you type."
  );
  form.setCollectEmail(false);
  form.setLimitOneResponsePerUser(false);
  form.setConfirmationMessage("thanks. we read every one.");
  form.setProgressBar(true);

  form.addTextItem().setTitle("what school are you at?").setRequired(true);

  form
    .addMultipleChoiceItem()
    .setTitle("what year?")
    .setChoiceValues(["first year", "sophomore", "junior", "senior", "grad", "other"])
    .setRequired(true);

  form
    .addMultipleChoiceItem()
    .setTitle("how long have you used smooth?")
    .setChoiceValues(["just installed", "a few days", "a few weeks", "a month or more"])
    .setRequired(true);

  form
    .addCheckboxItem()
    .setTitle("what's connected?")
    .setChoiceValues(["canvas", "gradescope", "ed discussion", "nothing yet"]);

  form
    .addMultipleChoiceItem()
    .setTitle("how often do you open it?")
    .setChoiceValues(["every day", "a few times a week", "once a week", "rarely"]);

  form
    .addCheckboxItem()
    .setTitle("which parts do you actually use?")
    .setChoiceValues([
      "the todo list",
      "reminders",
      "the smooth sweeper (the 10-minute alarm)",
      "ask / the tree",
      "the megaphone (announcements)",
      "the widget",
      "adding my own tasks",
    ]);

  form
    .addScaleItem()
    .setTitle("how much do you trust the list to be complete?")
    .setBounds(1, 5)
    .setLabels("missing things", "everything's there");

  form
    .addMultipleChoiceItem()
    .setTitle("did the sweeper ever save you from missing a deadline?")
    .setChoiceValues(["yes", "not yet", "i turned it off", "didn't know it existed"]);

  form
    .addScaleItem()
    .setTitle("how good are the tree's answers?")
    .setBounds(1, 5)
    .setLabels("wrong or empty", "spot on");

  form.addParagraphTextItem().setTitle("what did it get wrong, or what couldn't it answer?");

  form
    .addParagraphTextItem()
    .setTitle("what's the one thing you wish smooth did?")
    .setRequired(true);

  form.addParagraphTextItem().setTitle("anything broken or annoying?");

  form
    .addScaleItem()
    .setTitle("would you tell a friend to install it?")
    .setBounds(0, 10)
    .setLabels("no", "already did");

  var email = form.addTextItem().setTitle("email, only if you want a reply");
  email.setValidation(
    FormApp.createTextValidation().requireTextIsEmail().setHelpText("an email address, or leave it blank").build()
  );

  var sheet = SpreadsheetApp.create("smooth feedback (responses)");
  form.setDestination(FormApp.DestinationType.SPREADSHEET, sheet.getId());

  Logger.log("edit: " + form.getEditUrl());
  Logger.log("share: " + form.getPublishedUrl());
  Logger.log("responses: " + sheet.getUrl());
}

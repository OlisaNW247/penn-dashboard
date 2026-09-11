const STORAGE_KEY = "smooth-prototype-assignments-v2";

const palette = {
  tomato: "#F07256",
  marigold: "#F7A844",
  lemon: "#F5D353",
  teal: "#40B3A5",
  cobalt: "#699AE7",
  grape: "#AF85F0",
};

const seedTasks = [
  { id: "fnar-review", course: "FNAR 3230", title: "Sketchbook review", offsetHours: -96 },
  { id: "cis-pset-5", course: "CIS 1210", title: "PSet 5: graph algorithms", offsetHours: -48 },
  { id: "econ-pset-3", course: "ECON 1", title: "Problem set 3", offsetHours: 5 },
  { id: "mgmt-reading-7", course: "MGMT 1010", title: "Reading response 7", offsetHours: 9 },
  { id: "meam-lab-4", course: "MEAM 1010", title: "Lab report 4", weekday: 0 },
  { id: "cis-pset-6", course: "CIS 1210", title: "PSet 6: hashing", weekday: 1 },
  { id: "econ-midterm", course: "ECON 1", title: "Midterm study guide", weekday: 2 },
  { id: "mgmt-case", course: "MGMT 1010", title: "Group case writeup", weekday: 3 },
];

const list = document.querySelector("#assignmentList");
const tabs = [...document.querySelectorAll(".segment")];
const addSheet = document.querySelector("#addSheet");
const backdrop = document.querySelector("#sheetBackdrop");
const form = document.querySelector("#addForm");
const dueInput = document.querySelector("#dueInput");
const menu = document.querySelector("#prototypeMenu");
const menuButton = document.querySelector("#openMenu");
const toast = document.querySelector("#toast");

let activeFilter = "week";
let assignments = loadAssignments();
let toastTimer;

function seededAssignments() {
  const now = Date.now();
  return seedTasks.map((task) => ({
    ...task,
    dueAt: Number.isFinite(task.offsetHours)
      ? now + task.offsetHours * 60 * 60 * 1000
      : nextWeekday(task.weekday).getTime(),
    done: false,
  }));
}

function nextWeekday(weekday) {
  const due = new Date();
  let daysAhead = (weekday - due.getDay() + 7) % 7;
  if (daysAhead === 0) daysAhead = 7;
  due.setDate(due.getDate() + daysAhead);
  due.setHours(17, 0, 0, 0);
  return due;
}

function loadAssignments() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY));
    return Array.isArray(saved) ? saved : seededAssignments();
  } catch {
    return seededAssignments();
  }
}

function saveAssignments() {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(assignments));
}

function dueMeta(assignment) {
  const now = new Date();
  const due = new Date(assignment.dueAt);
  const diffHours = (due - now) / 3_600_000;
  const dayDiff = calendarDayDifference(now, due);

  if (diffHours < 0) {
    const daysLate = Math.max(1, Math.round(Math.abs(diffHours) / 24));
    return { group: "overdue", color: "tomato", value: `${daysLate}d`, qualifier: "late", rank: 0 };
  }

  if (diffHours <= 24) {
    return {
      group: "today",
      color: diffHours <= 7 ? "marigold" : "lemon",
      value: `${Math.max(1, Math.round(diffHours))}h`,
      qualifier: "",
      rank: 1,
    };
  }

  const weekday = new Intl.DateTimeFormat("en-US", { weekday: "short" }).format(due);
  let color = "grape";
  if (due.getDay() === 0 || due.getDay() === 6) color = "teal";
  else if (due.getDay() === 1) color = "teal";
  else if (due.getDay() === 2) color = "cobalt";

  return { group: "week", color, value: weekday, qualifier: "", rank: 2 };
}

function calendarDayDifference(from, to) {
  const start = new Date(from.getFullYear(), from.getMonth(), from.getDate());
  const end = new Date(to.getFullYear(), to.getMonth(), to.getDate());
  return Math.round((end - start) / 86_400_000);
}

function visibleAssignments() {
  if (activeFilter === "done") return assignments.filter((item) => item.done);
  if (activeFilter === "week") {
    return assignments.filter((item) => !item.done && calendarDayDifference(new Date(), new Date(item.dueAt)) <= 7);
  }
  return assignments.filter((item) => !item.done);
}

function render() {
  const visible = visibleAssignments().sort((a, b) => a.dueAt - b.dueAt);
  const groups = activeFilter === "done"
    ? [{ key: "done", label: "Finished", tasks: visible }]
    : [
        { key: "overdue", label: "Overdue", tasks: visible.filter((item) => dueMeta(item).group === "overdue") },
        { key: "today", label: "Today", tasks: visible.filter((item) => dueMeta(item).group === "today") },
        { key: "week", label: activeFilter === "all" ? "Coming up" : "Rest of week", tasks: visible.filter((item) => dueMeta(item).group === "week") },
      ];

  const populated = groups.filter((group) => group.tasks.length > 0);
  if (!populated.length) {
    const copy = activeFilter === "done"
      ? ["Nothing finished yet", "Tap an assignment and it’ll land here."]
      : ["You’re all smooth", "No assignments in this view."];
    list.innerHTML = `<div class="empty-state"><strong>${copy[0]}</strong><span>${copy[1]}</span></div>`;
  } else {
    list.innerHTML = populated.map(groupTemplate).join("");
  }

  const leftThisWeek = assignments.filter((item) => {
    const meta = dueMeta(item);
    return !item.done && meta.group !== "overdue" && calendarDayDifference(new Date(), new Date(item.dueAt)) <= 7;
  }).length;
  document.querySelector("#weekCount").textContent = leftThisWeek;
  bindTaskCards();
}

function groupTemplate(group) {
  return `
    <section class="task-group" aria-labelledby="group-${group.key}">
      <h2 class="section-heading" id="group-${group.key}">
        <span class="section-chip">${group.label}</span>
      </h2>
      <div class="tasks">${group.tasks.map(taskTemplate).join("")}</div>
    </section>`;
}

function taskTemplate(task) {
  const meta = dueMeta(task);
  const qualifier = meta.qualifier ? `<small>${meta.qualifier}</small>` : "";
  return `
    <article class="task-card${task.done ? " done" : ""}" data-id="${escapeHTML(task.id)}" style="--fill:${palette[meta.color]}" role="button" tabindex="0" aria-label="${task.done ? "Mark not done" : "Mark done"}: ${escapeHTML(task.title)}" aria-pressed="${task.done}">
      <div class="task-copy">
        <span class="course-code">${escapeHTML(task.course)}</span>
        <h3 class="task-title">${escapeHTML(task.title)}</h3>
      </div>
      <div class="due-value" aria-label="${escapeHTML(meta.value)} ${escapeHTML(meta.qualifier)}"><strong>${escapeHTML(meta.value)}</strong>${qualifier}</div>
    </article>`;
}

function escapeHTML(value) {
  return String(value).replace(/[&<>'"]/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "'": "&#39;",
    '"': "&quot;",
  })[char]);
}

function bindTaskCards() {
  document.querySelectorAll(".task-card").forEach((card) => {
    const toggleTask = () => {
      const task = assignments.find((item) => item.id === card.dataset.id);
      if (!task) return;

      if (activeFilter !== "done") {
        card.classList.add("removing");
        window.setTimeout(() => {
          task.done = true;
          saveAssignments();
          render();
          showToast("Marked done");
        }, 190);
      } else {
        task.done = false;
        saveAssignments();
        render();
        showToast("Moved back to assignments");
      }
    };

    card.addEventListener("click", toggleTask);
    card.addEventListener("keydown", (event) => {
      if (event.key !== "Enter" && event.key !== " ") return;
      event.preventDefault();
      toggleTask();
    });
  });
}

function showToast(message) {
  window.clearTimeout(toastTimer);
  toast.textContent = message;
  toast.classList.add("visible");
  toastTimer = window.setTimeout(() => toast.classList.remove("visible"), 1800);
}

function openSheet() {
  addSheet.hidden = false;
  backdrop.hidden = false;
  const initialDue = new Date(Date.now() + 24 * 60 * 60 * 1000);
  initialDue.setMinutes(Math.ceil(initialDue.getMinutes() / 15) * 15, 0, 0);
  dueInput.value = toLocalInputValue(initialDue);
  document.body.style.overflow = "hidden";
  window.setTimeout(() => document.querySelector("#courseInput").focus(), 0);
}

function closeSheet() {
  addSheet.hidden = true;
  backdrop.hidden = true;
  document.body.style.overflow = "";
  document.querySelector("#openAdd").focus();
}

function toLocalInputValue(date) {
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

tabs.forEach((tab) => {
  tab.addEventListener("click", () => {
    activeFilter = tab.dataset.filter;
    tabs.forEach((item) => {
      const active = item === tab;
      item.classList.toggle("active", active);
      item.setAttribute("aria-pressed", String(active));
    });
    render();
  });
});

document.querySelector("#openAdd").addEventListener("click", openSheet);
document.querySelector("#closeAdd").addEventListener("click", closeSheet);
backdrop.addEventListener("click", closeSheet);

menuButton.addEventListener("click", () => {
  menu.hidden = !menu.hidden;
  menuButton.setAttribute("aria-expanded", String(!menu.hidden));
});

document.querySelector("#resetData").addEventListener("click", () => {
  assignments = seededAssignments();
  saveAssignments();
  menu.hidden = true;
  menuButton.setAttribute("aria-expanded", "false");
  render();
  showToast("Prototype reset");
});

form.addEventListener("submit", (event) => {
  event.preventDefault();
  const data = new FormData(form);
  const dueAt = new Date(data.get("due")).getTime();
  assignments.push({
    id: `manual-${Date.now()}`,
    course: String(data.get("course")).trim().toUpperCase(),
    title: String(data.get("title")).trim(),
    dueAt,
    done: false,
  });
  saveAssignments();
  form.reset();
  closeSheet();
  activeFilter = "all";
  tabs.forEach((tab) => {
    const active = tab.dataset.filter === "all";
    tab.classList.toggle("active", active);
    tab.setAttribute("aria-pressed", String(active));
  });
  render();
  showToast("Assignment added");
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !addSheet.hidden) closeSheet();
});

render();

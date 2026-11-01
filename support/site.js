// Every page works as plain anchors and disclosures; this file only adds to them.
// Nothing typed here leaves the page: the report form hands text to the visitor's
// own mail app, and the only stored value is the theme choice.
const root = document.documentElement;
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)");

const announcer = document.createElement("p");
announcer.className = "sr-only";
announcer.setAttribute("role", "status");
document.body.append(announcer);

/* Theme ------------------------------------------------------------------ */

const systemDark = matchMedia("(prefers-color-scheme: dark)");
const themeToggle = document.querySelector(".theme-toggle");
const themeColors = document.querySelectorAll('meta[name="theme-color"]');

const isDark = () => (root.dataset.theme ?? (systemDark.matches ? "dark" : "light")) === "dark";

function reflectTheme() {
  const dark = isDark();
  themeToggle.setAttribute("aria-pressed", String(dark));
  themeColors.forEach((meta) => meta.setAttribute("content", dark ? "#141414" : "#f2f2f2"));
}

function setTheme(theme) {
  root.dataset.theme = theme;
  try {
    localStorage.setItem("fffilm-theme", theme);
  } catch {
    // Private windows may refuse storage; the choice then lasts this page only.
  }
  reflectTheme();
}

themeToggle.addEventListener("click", () => {
  const next = isDark() ? "light" : "dark";
  if (!document.startViewTransition || reduceMotion.matches) {
    setTheme(next);
    return;
  }
  const lamp = themeToggle.querySelector(".theme-lamp").getBoundingClientRect();
  const x = lamp.left + lamp.width / 2;
  const y = lamp.top + lamp.height / 2;
  root.style.setProperty("--lamp-x", `${x}px`);
  root.style.setProperty("--lamp-y", `${y}px`);
  root.style.setProperty("--lamp-r", `${Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y))}px`);
  document.startViewTransition(() => setTheme(next));
});

systemDark.addEventListener("change", reflectTheme);
reflectTheme();

/* Section index and rail ------------------------------------------------- */

// Marks the section being read in the index; without scripting it stays plain anchors.
const links = [...document.querySelectorAll(".section-index a")];
const sections = links.map((link) => document.querySelector(link.hash));
const rail = document.querySelector(".rail");
const footer = document.querySelector(".site-footer");
const frames = sections.map(() => {
  const frame = document.createElement("i");
  frame.className = "rail-frame";
  return rail.appendChild(frame);
});
let spans = [];
let scheduled = 0;
let currentIndex = -1;

function measure() {
  const tops = sections.map((section) => section.getBoundingClientRect().top + scrollY);
  const end = footer.getBoundingClientRect().top + scrollY;
  spans = tops.map((top, index) => ({ top, bottom: tops[index + 1] ?? end }));
  frames.forEach((frame, index) => {
    frame.style.top = `${spans[index].top}px`;
    frame.style.height = `${spans[index].bottom - spans[index].top - 8}px`;
  });
}

function markCurrent() {
  scheduled = 0;
  const atEnd = innerHeight + scrollY >= root.scrollHeight - 2;
  const readingLine = innerHeight * 0.35;
  let current = 0;
  sections.forEach((section, index) => {
    if (section.getBoundingClientRect().top <= readingLine) current = index;
  });
  if (atEnd) current = sections.length - 1;

  const line = atEnd ? Infinity : scrollY + readingLine;
  frames.forEach((frame, index) => {
    const { top, bottom } = spans[index];
    frame.style.setProperty("--read", Math.min(1, Math.max(0, (line - top) / (bottom - top))));
  });

  if (current === currentIndex) return;
  currentIndex = current;
  links.forEach((link, index) => {
    if (index === current) link.setAttribute("aria-current", "location");
    else link.removeAttribute("aria-current");
  });

  // On phones the index is a sideways bar; keep the current link in it.
  const bar = links[current].closest(".section-index");
  if (bar.scrollWidth > bar.clientWidth) {
    bar.scrollTo({
      left: links[current].offsetLeft - (bar.clientWidth - links[current].offsetWidth) / 2,
      behavior: reduceMotion.matches ? "auto" : "smooth",
    });
  }
}

function schedule() {
  scheduled ||= requestAnimationFrame(markCurrent);
}

if (links.length) {
  measure();
  addEventListener("scroll", schedule, { passive: true });
  addEventListener("resize", schedule);
  // Opening an answer or filtering a list moves every section below it.
  new ResizeObserver(() => {
    measure();
    schedule();
  }).observe(document.body);
  markCurrent();
}

/* Filter chips ----------------------------------------------------------- */

// Chips carry data-filter; the rows they filter carry space-separated data-topics.
function setPressed(chips, value) {
  chips.forEach((chip) => chip.setAttribute("aria-pressed", String(chip.dataset.filter === value)));
}

function addCounts(chips, rows) {
  chips.forEach((chip) => {
    const { filter } = chip.dataset;
    const count = document.createElement("span");
    count.className = "chip-count";
    count.textContent = filter === "all" ? rows.length : rows.filter((row) => row.topics.includes(filter)).length;
    chip.append(count);
  });
}

/* Privacy ledger --------------------------------------------------------- */

const ledgerChips = [...document.querySelectorAll(".chips-ledger .chip")];

if (ledgerChips.length) {
  const rows = [...document.querySelectorAll(".ledger .data-row")].map((el) => ({
    el,
    topics: el.dataset.topics.split(" "),
  }));
  addCounts(ledgerChips, rows);
  ledgerChips.forEach((chip) => {
    chip.addEventListener("click", () => {
      const { filter } = chip.dataset;
      setPressed(ledgerChips, filter);
      rows.forEach(({ el, topics }) => {
        el.hidden = filter !== "all" && !topics.includes(filter);
      });
    });
  });
}

/* FAQ finder ------------------------------------------------------------- */

const search = document.querySelector("#faq-search");

if (search) {
  const chips = [...document.querySelectorAll(".finder .chip")];
  const clear = document.querySelector(".finder-clear");
  const count = document.querySelector(".faq-count");
  const empty = document.querySelector(".faq-empty");
  const emptyQuery = document.querySelector(".faq-empty-query");
  const items = [...document.querySelectorAll(".faq")].map((el) => ({
    el,
    topics: el.dataset.topics.split(" "),
    text: `${el.textContent} ${el.dataset.terms}`.toLowerCase(),
  }));
  const openedBySearch = new Set();
  let topic = "all";

  addCounts(chips, items);

  function highlight(terms, shown) {
    if (!window.Highlight || !CSS.highlights) return;
    const ranges = [];
    shown.forEach(({ el }) => {
      const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) {
        const node = walker.currentNode;
        const text = node.data.toLowerCase();
        terms.forEach((term) => {
          for (let at = text.indexOf(term); at !== -1; at = text.indexOf(term, at + term.length)) {
            const range = new Range();
            range.setStart(node, at);
            range.setEnd(node, at + term.length);
            ranges.push(range);
          }
        });
      }
    });
    CSS.highlights.set("faq-hit", new Highlight(...ranges));
  }

  function apply() {
    const query = search.value.trim();
    const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
    const shown = items.filter((item) => {
      const hit = (topic === "all" || item.topics.includes(topic)) && terms.every((term) => item.text.includes(term));
      item.el.hidden = !hit;
      return hit;
    });

    // A short result list opens itself, so the matching sentence is on screen.
    openedBySearch.forEach((el) => {
      el.open = false;
    });
    openedBySearch.clear();
    if (terms.length && shown.length <= 3) {
      shown.forEach(({ el }) => {
        if (el.open) return;
        el.open = true;
        openedBySearch.add(el);
      });
    }

    highlight(terms, shown);
    clear.hidden = !search.value;
    count.textContent = `${shown.length} 个问题`;
    empty.hidden = shown.length > 0;
    emptyQuery.textContent = query;
  }

  function reset() {
    search.value = "";
    topic = "all";
    setPressed(chips, topic);
    apply();
  }

  chips.forEach((chip) => {
    chip.addEventListener("click", () => {
      topic = chip.dataset.filter;
      setPressed(chips, topic);
      apply();
    });
  });

  search.addEventListener("input", apply);
  search.addEventListener("keydown", (event) => {
    if (event.key === "Escape") {
      reset();
      search.blur();
    }
    if (event.key === "Enter") {
      event.preventDefault();
      if (!count.textContent.startsWith("0")) document.querySelector("#faq").scrollIntoView();
    }
  });
  clear.addEventListener("click", () => {
    reset();
    search.focus();
  });

  addEventListener("keydown", (event) => {
    const typing = event.target.closest?.("input, textarea, select, [contenteditable]");
    if (event.key === "/" && !typing && !event.metaKey && !event.ctrlKey && !event.altKey) {
      event.preventDefault();
      search.focus();
    }
  });

  // support.html#q-units opens that answer; support.html?q=频闪 starts a search.
  function openTarget() {
    const target = document.getElementById(location.hash.slice(1));
    if (!target?.matches(".faq")) return;
    if (target.hidden) reset();
    target.open = true;
    target.scrollIntoView();
  }

  search.value = new URLSearchParams(location.search).get("q") ?? "";
  apply();
  openTarget();
  addEventListener("hashchange", openTarget);

  // An unanswered search becomes the first line of the report.
  document.querySelector("[data-carry-query]").addEventListener("click", (event) => {
    const issue = document.querySelector("#r-issue");
    event.preventDefault();
    issue.value ||= search.value.trim();
    issue.closest(".report").scrollIntoView();
    issue.focus({ preventScroll: true });
  });
}

/* Copying ---------------------------------------------------------------- */

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

document.querySelectorAll("[data-copy]").forEach((button) => {
  const label = button.textContent;
  let restore = 0;
  button.addEventListener("click", async () => {
    const copied = await copyText(button.dataset.copy);
    button.textContent = copied ? "已复制" : "请手动复制";
    announcer.textContent = copied ? "邮箱地址已复制" : "无法访问剪贴板，请手动选择邮箱地址";
    clearTimeout(restore);
    restore = setTimeout(() => {
      button.textContent = label;
    }, 1800);
  });
});

/* Report form ------------------------------------------------------------ */

const report = document.querySelector(".report");

if (report) {
  // Some mail apps truncate longer links; past this the text goes by clipboard.
  const mailtoLimit = 1800;
  const to = report.dataset.to;
  const issue = report.querySelector("#r-issue");
  const issueError = report.querySelector("#r-issue-error");
  const status = report.querySelector(".report-status");
  const groups = [...report.querySelectorAll("[data-for]")];

  function showGroups() {
    const chosen = report.querySelector("[data-report-feature] input:checked")?.dataset.group ?? "general";
    groups.forEach((group) => {
      const active = group.dataset.for === chosen;
      group.hidden = !active;
      group.disabled = !active; // disabled fields stay out of the mail
    });
  }

  function validated() {
    const valid = Boolean(issue.value.trim());
    issueError.hidden = valid;
    if (valid) issue.removeAttribute("aria-invalid");
    else {
      issue.setAttribute("aria-invalid", "true");
      issue.focus();
    }
    return valid;
  }

  function compose() {
    return [...new FormData(report)]
      .map(([label, value]) => [label, value.trim()])
      .filter(([, value]) => value)
      .map(([label, value]) => (value.includes("\n") ? `${label}：\n${value}` : `${label}：${value}`))
      .join("\n\n");
  }

  function subject() {
    const feature = report.querySelector("[data-report-feature] input:checked")?.value;
    return feature ? `FFFilm 问题反馈 · ${feature}` : "FFFilm 问题反馈";
  }

  report.addEventListener("change", showGroups);
  issue.addEventListener("input", () => {
    if (issue.value.trim()) {
      issueError.hidden = true;
      issue.removeAttribute("aria-invalid");
    }
  });

  report.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!validated()) return;
    const body = compose();
    const base = `mailto:${to}?subject=${encodeURIComponent(subject())}`;
    const full = `${base}&body=${encodeURIComponent(body.replaceAll("\n", "\r\n"))}`;
    if (full.length <= mailtoLimit) {
      location.href = full;
      status.textContent = `正在打开邮件应用。没有反应时，请复制内容后发送到 ${to}。`;
      return;
    }
    const copied = await copyText(body);
    location.href = base;
    status.textContent = copied
      ? "内容较长，已复制到剪贴板，请粘贴到邮件正文。"
      : `内容较长，请缩短后重试，或手动发送到 ${to}。`;
  });

  report.querySelector("[data-report-copy]").addEventListener("click", async () => {
    if (!validated()) return;
    const copied = await copyText(`${subject()}\n\n${compose()}`);
    status.textContent = copied ? `已复制，请粘贴到邮件发送至 ${to}。` : "无法访问剪贴板，请手动选择表单内容。";
  });

  showGroups();
}

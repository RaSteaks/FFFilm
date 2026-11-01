// Marks the section being read in the index; without scripting it stays plain anchors.
const links = [...document.querySelectorAll(".section-index a")];
const sections = links.map((link) => document.querySelector(link.hash));
let frame = 0;

function markCurrent() {
  frame = 0;
  const readingLine = innerHeight * 0.35;
  let current = 0;
  sections.forEach((section, index) => {
    if (section.getBoundingClientRect().top <= readingLine) current = index;
  });
  if (innerHeight + scrollY >= document.documentElement.scrollHeight - 2) current = sections.length - 1;
  links.forEach((link, index) => {
    if (index === current) link.setAttribute("aria-current", "location");
    else link.removeAttribute("aria-current");
  });
}

function schedule() {
  frame ||= requestAnimationFrame(markCurrent);
}

addEventListener("scroll", schedule, { passive: true });
addEventListener("resize", schedule);
markCurrent();

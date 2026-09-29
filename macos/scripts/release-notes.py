#!/usr/bin/env python3
"""Release notes for a Mac release, written for the update window and for GitHub.

    scripts/release-notes.py <version> <html output> <markdown output>

Notes come from `Release-Note:` lines in the messages of commits that touch macos/ since the
previous mac-v* tag. Start a note with "New:", "Improved:" or "Fixed:" to pick its icon, e.g.

    Release-Note: New: See every connected iPhone in All Devices.

The HTML is embedded in the Sparkle feed, so the update window shows a designed page instead of
a website. It also lists the three releases before, for people who skipped updates.
"""
import datetime
import html
import re
import subprocess
import sys

KINDS = {
    "new": ("New", "#0a84ff", '<path d="M8 1.5l1.6 4.2 4.4.3-3.4 2.8 1.1 4.3L8 10.7l-3.7 2.4 1.1-4.3L2 6l4.4-.3z"/>'),
    "improved": ("Improved", "#30b158", '<path d="M8 13V3.5M3.8 7.7 8 3.5l4.2 4.2" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'),
    "fixed": ("Fixed", "#ff9500", '<path d="M3.5 8.4 6.6 11.5 12.5 4.8" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'),
}
FALLBACK = [("improved", "Improvements and bug fixes.")]


def git(*args: str) -> str:
    return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout


def notes(revisions: str) -> list[tuple[str, str]]:
    """(kind, text) for every Release-Note line in the range: new, improved, then fixed, each oldest first."""
    found = []
    for message in reversed(git("log", "--format=%B%x00", revisions, "--", ".").split("\0")):
        for line in message.splitlines():
            match = re.match(r"^Release-Note:\s*(.+)$", line.strip())
            if not match:
                continue
            text = match.group(1).strip()
            kind = "improved"
            prefix = re.match(r"^(New|Improved|Fixed):\s*(.+)$", text, re.IGNORECASE)
            if prefix:
                kind, text = prefix.group(1).lower(), prefix.group(2)
            found.append((kind, text))
    return sorted(found, key=lambda entry: list(KINDS).index(entry[0]))


def release_date(tag: str) -> str:
    day = datetime.date.fromisoformat(git("log", "-1", "--format=%cs", tag).strip())
    return f"{day:%B} {day.day}, {day.year}"


def items_html(entries: list[tuple[str, str]]) -> str:
    rows = []
    for kind, text in entries:
        label, color, icon = KINDS[kind]
        rows.append(
            f'<li><span class="icon" style="background:{color}" title="{label}">'
            f'<svg viewBox="0 0 16 16" width="13" height="13" fill="#fff">{icon}</svg></span>'
            f"<span>{html.escape(text)}</span></li>")
    return "<ul>" + "".join(rows) + "</ul>"


def main() -> None:
    version, html_path, markdown_path = sys.argv[1:4]
    tags = git("tag", "--list", "mac-v*", "--sort=-v:refname").split()
    current = notes(f"{tags[0]}..HEAD" if tags else "HEAD") or FALLBACK
    earlier = []
    for newer, older in zip(tags, tags[1:]):
        entries = notes(f"{older}..{newer}")
        if entries:
            earlier.append((newer.removeprefix("mac-v"), release_date(newer), entries))
        if len(earlier) == 3:
            break

    today = datetime.date.today()
    sections = [
        f'<h1>What’s New in Mobdev {html.escape(version)}</h1>',
        f'<p class="date">{today:%B} {today.day}, {today.year}</p>',
        items_html(current),
    ]
    if earlier:
        sections.append("<h2>Earlier Updates</h2>")
        for old_version, date, entries in earlier:
            sections.append(f'<h3>Mobdev {html.escape(old_version)} <span>{date}</span></h3>')
            sections.append(items_html(entries))
    page = f"""<!doctype html>
<html><head><meta charset="utf-8"><style>
:root {{ color-scheme: light dark; }}
body {{ margin: 0; padding: 20px 22px 26px; font: 13px/1.45 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
  color: #1d1d1f; -webkit-font-smoothing: antialiased; }}
h1 {{ margin: 0; font-size: 21px; font-weight: 700; letter-spacing: -0.02em; }}
.date {{ margin: 3px 0 16px; color: #86868b; }}
ul {{ list-style: none; margin: 0; padding: 0; display: grid; gap: 7px; }}
li {{ display: flex; gap: 11px; align-items: flex-start; padding: 10px 12px; border-radius: 11px;
  background: rgba(0, 0, 0, 0.045); }}
.icon {{ flex: none; width: 22px; height: 22px; border-radius: 7px; display: grid; place-items: center;
  margin-top: -1px; }}
h2 {{ margin: 26px 0 10px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em;
  color: #86868b; }}
h3 {{ margin: 16px 0 8px; font-size: 13px; font-weight: 600; }}
h3 span {{ font-weight: 400; color: #86868b; margin-left: 6px; }}
h3 + ul li {{ padding: 7px 10px; }}
@media (prefers-color-scheme: dark) {{
  body {{ color: #f5f5f7; }}
  li {{ background: rgba(255, 255, 255, 0.07); }}
  .date, h2, h3 span {{ color: #98989d; }}
}}
</style></head><body>
{"".join(sections)}
</body></html>
"""
    with open(html_path, "w") as file:
        file.write(page)

    lines = []
    for kind in KINDS:
        texts = [text for entry_kind, text in current if entry_kind == kind]
        if texts:
            lines.append(f"### {KINDS[kind][0]}")
            lines.extend(f"- {text}" for text in texts)
            lines.append("")
    with open(markdown_path, "w") as file:
        file.write("\n".join(lines))


if __name__ == "__main__":
    main()

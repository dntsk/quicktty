#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
from html import unescape
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / "site"
EXPECTED_PAGES = {
    SITE / "index.html",
    SITE / "docs" / "index.html",
    SITE / "releases" / "index.html",
    SITE / "privacy" / "index.html",
}
LATEST_RELEASE_URL = "https://github.com/dntsk/quicktty/releases/latest"
EXTERNAL_SCHEMES = {"http", "https", "mailto", "tel"}
CONFIGURATION_REFERENCE = ROOT / "QuickTTY" / "Resources" / "configuration-reference.md"
AGENT_INTEGRATIONS = ROOT / "QuickTTY" / "Resources" / "AgentIntegrations"
AGENT_ADAPTER_IDS = (
    "claude", "codex", "grok", "pi", "omp", "campfire", "amp", "cursor",
    "gemini", "kiro", "antigravity", "opencode", "rovo-dev", "hermes",
    "copilot", "codebuddy", "droid", "qoder", "kimi", "ollama",
)


def section_between(source: str, start_marker: str, end_marker: str) -> str | None:
    start = source.find(start_marker)
    if start == -1:
        return None
    end = source.find(end_marker, start + len(start_marker))
    if end == -1:
        return None
    return source[start:end]


def div_block(source: str, marker: str) -> tuple[str, int, int] | None:
    start = source.find(marker)
    if start == -1:
        return None

    depth = 0
    for match in re.finditer(r"</?div\b[^>]*>", source[start:], flags=re.IGNORECASE):
        if match.group(0).startswith("</"):
            depth -= 1
            if depth == 0:
                end = start + match.end()
                return source[start:end], start, end
        else:
            depth += 1
    return None


def canonical_shortcuts(errors: list[str]) -> dict[str, str | None]:
    source = CONFIGURATION_REFERENCE.read_text(encoding="utf-8")
    section = section_between(
        source,
        "## Action registry and defaults",
        "## Sequential application and conflicts",
    )
    if section is None:
        errors.append(
            "QuickTTY/Resources/configuration-reference.md: missing canonical shortcut registry section"
        )
        return {}

    shortcuts: dict[str, str | None] = {}
    row_pattern = re.compile(
        r"^\|\s*`(?P<action>[^`]+)`\s*\|\s*`(?P<default>[^`]+)`\s*\|",
        flags=re.MULTILINE,
    )
    for match in row_pattern.finditer(section):
        action = match.group("action").strip()
        default = match.group("default").strip().casefold()
        if action in shortcuts:
            errors.append(
                "QuickTTY/Resources/configuration-reference.md: "
                f"duplicate canonical shortcut action: {action}"
            )
        shortcuts[action] = None if default == "disabled" else default

    if not shortcuts:
        errors.append(
            "QuickTTY/Resources/configuration-reference.md: canonical shortcut registry has no rows"
        )
    shortcuts["quicktty-global-toggle"] = "f12"
    return shortcuts


def docs_shortcuts(source: str, errors: list[str]) -> dict[str, str | None]:
    section = section_between(source, '<section id="keyboard-shortcuts">', "</section>")
    if section is None:
        errors.append("site/docs/index.html: missing keyboard shortcuts section")
        return {}

    table_pattern = re.compile(
        r'<table class="(?P<classes>[^"]*\bshortcut-table\b[^"]*)">(?P<body>.*?)</table>',
        flags=re.DOTALL,
    )
    tables = list(table_pattern.finditer(section))
    if not tables:
        errors.append("site/docs/index.html: missing shortcut category tables")

    primary = div_block(section, '<div class="primary-shortcut">')
    if primary is None:
        errors.append("site/docs/index.html: missing or malformed .primary-shortcut block")
    else:
        primary_source, primary_start, primary_end = primary
        for marker in ("Cmd+Opt+P", "toggle-presentation"):
            if marker not in primary_source:
                errors.append(
                    f"site/docs/index.html: .primary-shortcut block is missing {marker}"
                )
        if tables and (primary_start >= tables[0].start() or primary_end > tables[0].start()):
            errors.append(
                "site/docs/index.html: .primary-shortcut block must appear before shortcut category tables"
            )

    shortcuts: dict[str, str | None] = {}
    assigned_pattern = re.compile(
        r"<tr><td>[^<]+</td><td><kbd>(?P<chord>[^<]+)</kbd></td>"
        r"<td><code>(?P<action>[^<]+)</code>(?:(?!</td>).)*</td></tr>"
    )
    unassigned_pattern = re.compile(
        r"<tr><td>[^<]+</td><td><code>(?P<action>[^<]+)</code></td></tr>"
    )
    for table in tables:
        classes = table.group("classes").split()
        body_match = re.search(r"<tbody>(.*?)</tbody>", table.group("body"), flags=re.DOTALL)
        if body_match is None:
            errors.append("site/docs/index.html: shortcut table is missing tbody")
            continue
        rows = re.findall(r"<tr>.*?</tr>", body_match.group(1), flags=re.DOTALL)
        pattern = unassigned_pattern if "shortcut-table-compact" in classes else assigned_pattern
        for row in rows:
            normalized_row = row.strip()
            match = pattern.fullmatch(normalized_row)
            if match is None:
                display_row = re.sub(r"\s+", " ", normalized_row)
                errors.append(
                    f"site/docs/index.html: malformed shortcut table row: {display_row}"
                )
                continue
            action = unescape(match.group("action")).strip()
            default = None
            if pattern is assigned_pattern:
                default = unescape(match.group("chord")).strip().casefold()
            if action in shortcuts:
                errors.append(f"site/docs/index.html: duplicate shortcut action: {action}")
            shortcuts[action] = default
    return shortcuts


def compare_shortcuts(
    canonical: dict[str, str | None], documented: dict[str, str | None], errors: list[str]
) -> None:
    for action in sorted(canonical.keys() | documented.keys()):
        if action not in documented:
            expected = canonical[action] if canonical[action] is not None else "no default"
            errors.append(
                f"site/docs/index.html: missing shortcut action {action!r} (expected {expected})"
            )
        elif action not in canonical:
            actual = documented[action] if documented[action] is not None else "no default"
            errors.append(
                f"site/docs/index.html: extra shortcut action {action!r} (documented {actual})"
            )
        elif documented[action] != canonical[action]:
            expected = canonical[action] if canonical[action] is not None else "no default"
            actual = documented[action] if documented[action] is not None else "no default"
            errors.append(
                f"site/docs/index.html: shortcut mismatch for {action!r}: "
                f"expected {expected}, documented {actual}"
            )


def validate_bundled_example(
    docs_source: str, marker: str, bundled_path: Path, errors: list[str]
) -> None:
    marker_index = docs_source.find(marker)
    label = bundled_path.relative_to(ROOT)
    if marker_index == -1:
        errors.append(f"site/docs/index.html: missing bundled example marker {marker}")
        return

    match = re.search(r"<pre><code>(.*?)</code></pre>", docs_source[marker_index:], flags=re.DOTALL)
    if match is None:
        errors.append(f"site/docs/index.html: missing code block after {marker}")
        return

    documented = unescape(match.group(1)) + "\n"
    bundled = bundled_path.read_text(encoding="utf-8")
    if documented != bundled:
        errors.append(f"site/docs/index.html: embedded {marker} does not match {label}")


def require_markers(
    source: str, label: str, markers: tuple[str, ...], errors: list[str]
) -> None:
    for marker in markers:
        if marker not in source:
            errors.append(f"site/docs/index.html: {label} is missing required marker: {marker}")


def validate_helper_invocations(docs_source: str, errors: list[str]) -> None:
    marker = "supports exactly these invocation forms:"
    marker_index = docs_source.find(marker)
    if marker_index == -1:
        errors.append("site/docs/index.html: missing helper invocation forms marker")
        return

    match = re.search(r"<pre><code>(.*?)</code></pre>", docs_source[marker_index:], flags=re.DOTALL)
    if match is None:
        errors.append("site/docs/index.html: missing helper invocation forms code block")
        return

    expected = (
        "quicktty-progress claude working|waiting|failed|completed\n"
        "quicktty-progress codex working|waiting|failed|completed"
    )
    if unescape(match.group(1)) != expected:
        errors.append("site/docs/index.html: helper invocation forms do not match the contract")


class PageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.title_parts: list[str] = []
        self.in_title = False
        self.descriptions: list[str] = []
        self.canonicals: list[str] = []
        self.h1_count = 0
        self.has_skip_link = False
        self.images: list[dict[str, str]] = []
        self.references: list[tuple[str, str]] = []
        self.ids: set[str] = set()

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = {name: value or "" for name, value in attrs}
        if tag == "title":
            self.in_title = True
        elif tag == "meta" and values.get("name", "").lower() == "description":
            self.descriptions.append(values.get("content", "").strip())
        elif tag == "link" and "canonical" in values.get("rel", "").lower().split():
            self.canonicals.append(values.get("href", "").strip())
        elif tag == "h1":
            self.h1_count += 1
        elif tag == "a":
            classes = values.get("class", "").split()
            if "skip-link" in classes and values.get("href", "").startswith("#"):
                self.has_skip_link = True

        element_id = values.get("id", "").strip()
        if element_id:
            self.ids.add(element_id)
        if tag == "img":
            self.images.append(values)
        for attribute in ("href", "src"):
            if attribute in values:
                self.references.append((attribute, values[attribute].strip()))

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self.in_title = False

    def handle_data(self, data: str) -> None:
        if self.in_title:
            self.title_parts.append(data)

    @property
    def title(self) -> str:
        return "".join(self.title_parts).strip()


def local_target(page: Path, reference: str) -> tuple[Path, str] | None:
    parsed = urlsplit(reference)
    if parsed.scheme.lower() in EXTERNAL_SCHEMES or parsed.netloc:
        return None
    if parsed.scheme:
        return None

    path_text = unquote(parsed.path)
    if not path_text:
        target = page
    elif path_text.startswith("/"):
        target = SITE / path_text.lstrip("/")
    else:
        target = page.parent / path_text

    target = target.resolve()
    try:
        target.relative_to(SITE.resolve())
    except ValueError:
        return target, parsed.fragment

    if path_text.endswith("/") or target.is_dir():
        target /= "index.html"
    return target, unquote(parsed.fragment)


def main() -> int:
    errors: list[str] = []
    if not SITE.is_dir():
        print("site-check: site/ does not exist", file=sys.stderr)
        return 1

    html_files = sorted(SITE.rglob("*.html"))
    missing_pages = sorted(EXPECTED_PAGES.difference(html_files))
    for page in missing_pages:
        errors.append(f"missing required page: {page.relative_to(ROOT)}")
    if not html_files:
        errors.append("site/ contains no HTML pages")

    parsed_pages: dict[Path, PageParser] = {}
    page_sources: dict[Path, str] = {}
    for page in html_files:
        source = page.read_text(encoding="utf-8")
        parser = PageParser()
        try:
            parser.feed(source)
            parser.close()
        except Exception as error:
            errors.append(f"{page.relative_to(ROOT)}: invalid HTML: {error}")
            continue

        parsed_pages[page.resolve()] = parser
        page_sources[page.resolve()] = source
        label = page.relative_to(ROOT)

        if not parser.title:
            errors.append(f"{label}: missing nonempty title")
        if len(parser.descriptions) != 1 or not parser.descriptions[0]:
            errors.append(f"{label}: expected one nonempty meta description")
        if len(parser.canonicals) != 1 or not parser.canonicals[0]:
            errors.append(f"{label}: expected one nonempty canonical URL")
        if parser.h1_count != 1:
            errors.append(f"{label}: expected exactly one h1, found {parser.h1_count}")
        if not parser.has_skip_link:
            errors.append(f"{label}: missing skip link")

        for image in parser.images:
            if not image.get("alt", "").strip():
                errors.append(f"{label}: image is missing nonempty alt text")

        forbidden_patterns = {
            'href="#"': r'href\s*=\s*["\']#["\']',
            "TODO": r"\bTODO\b",
            "localhost URL": r"(?:https?:)?//localhost(?::\d+)?(?=[/?#\"'\s<]|$)",
            "open source claim": r"\bopen[\s-]+source\b",
        }
        for description, pattern in forbidden_patterns.items():
            if re.search(pattern, source, flags=re.IGNORECASE):
                errors.append(f"{label}: contains forbidden {description}")

    for page, parser in parsed_pages.items():
        label = page.relative_to(ROOT)
        for attribute, reference in parser.references:
            if not reference:
                errors.append(f"{label}: empty {attribute}")
                continue
            target_info = local_target(page, reference)
            if target_info is None:
                continue
            target, fragment = target_info
            try:
                target.relative_to(SITE.resolve())
            except ValueError:
                errors.append(f"{label}: local reference escapes site/: {reference}")
                continue
            if not target.exists():
                errors.append(f"{label}: missing local target for {reference}")
                continue
            if fragment and target.suffix.lower() == ".html":
                target_parser = parsed_pages.get(target.resolve())
                if target_parser is None or fragment not in target_parser.ids:
                    errors.append(f"{label}: missing fragment target for {reference}")

    cname = SITE / "CNAME"
    if not cname.is_file() or cname.read_text(encoding="utf-8").strip() != "quicktty.app":
        errors.append("site/CNAME must contain only quicktty.app")

    home_source = page_sources.get((SITE / "index.html").resolve(), "")
    if LATEST_RELEASE_URL not in home_source:
        errors.append("site/index.html: missing future-proof releases/latest URL")
    versioned_dmg_url = re.compile(
        r"""(?ix)
        (?=[^\s"'<>]*
            (?<![0-9A-Za-z.])v?
            (?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)
            (?![0-9A-Za-z.])
        )
        [^\s"'<>]*\.dmg(?=[?#\s"'<>)]|$)
        """
    )
    if versioned_dmg_url.search(home_source):
        errors.append("site/index.html: contains a version-pinned DMG URL")

    docs_path = (SITE / "docs" / "index.html").resolve()
    docs_source = page_sources.get(docs_path, "")
    docs_parser = parsed_pages.get(docs_path)
    if docs_parser is not None:
        for attribute, reference in docs_parser.references:
            parsed_reference = urlsplit(reference)
            hostname = (parsed_reference.hostname or "").lower().removeprefix("www.")
            if (
                hostname == "github.com"
                and re.match(
                    r"^/dntsk/quicktty/(?:blob|tree)/.*\.md$",
                    parsed_reference.path,
                    flags=re.IGNORECASE,
                )
            ):
                errors.append(
                    "site/docs/index.html: repository Markdown link is not self-contained: "
                    f"{reference}"
                )
    compare_shortcuts(canonical_shortcuts(errors), docs_shortcuts(docs_source, errors), errors)

    quake_guide = section_between(docs_source, '<section id="quake-mode">', "</section>")
    if quake_guide is None:
        errors.append("site/docs/index.html: missing Quake Mode guide")
    else:
        require_markers(
            quake_guide,
            "Quake Mode guide",
            (
                "<kbd>Cmd+Opt+P</kbd>",
                "between Normal and Quake presentations",
                "same panes and live processes",
                "no shell is restarted",
                "<kbd>F12</kbd>",
                "globally shows or hides it",
            ),
            errors,
        )

    validate_bundled_example(
        docs_source,
        "claude-settings.example.json",
        AGENT_INTEGRATIONS / "claude-settings.example.json",
        errors,
    )
    validate_bundled_example(
        docs_source,
        "codex-hooks.example.json",
        AGENT_INTEGRATIONS / "codex-hooks.example.json",
        errors,
    )

    agent_guide = section_between(
        docs_source, '<section id="coding-agent-integrations">', "</section>"
    )
    if agent_guide is None:
        errors.append("site/docs/index.html: missing coding agent integrations guide")
    else:
        require_markers(
            agent_guide,
            "coding agent integrations guide",
            (
                "quicktty-restore-agent-sessions",
                "explicit confirmation",
                "literal <code>yes</code>",
                "no arbitrary command",
                "fresh shell",
                "Retry",
                "Forget",
                "no silent configuration writes",
                "valid semantic version",
                "current Pi <code>0.84.4</code>",
                "11 native, 3 wrapper, and 6 blocked",
                "QUICKTTY_PANE_ID",
                "QUICKTTY_AGENT_SOCKET",
                "QUICKTTY_INSTANCE_ID",
                "QUICKTTY_PANE_TOKEN",
                "QUICKTTY_AGENT_HELPER",
            ),
            errors,
        )
        documented_agent_ids = tuple(
            re.findall(r'<tr data-agent-id="([a-z0-9-]+)">', agent_guide)
        )
        if documented_agent_ids != AGENT_ADAPTER_IDS:
            errors.append(
                "site/docs/index.html: agent registry must match the exact ordered 20 IDs"
            )

    pi_guide = section_between(docs_source, "<h3>Pi</h3>", "<h3>Claude Code")
    if pi_guide is None:
        errors.append("site/docs/index.html: missing Pi agent guide")
    else:
        require_markers(
            pi_guide,
            "Pi agent guide",
            (
                "<code>/settings</code>",
                "Terminal progress",
                "<code>terminal.showTerminalProgress</code>",
                "off by default",
                "No helper, hooks, or extensions",
                "<code>agent_start</code>",
                "keepalive",
                "<code>agent_end</code>",
            ),
            errors,
        )

    claude_guide = section_between(docs_source, "<h3>Claude Code", "<h3>Codex")
    if claude_guide is None:
        errors.append("site/docs/index.html: missing Claude Code agent guide")
    else:
        require_markers(
            claude_guide,
            "Claude Code agent guide",
            (
                "no controlling TTY",
                "universal <code>terminalSequence</code> field",
                "writes nothing else to stdout",
                "no stdin, prompt, transcript, or environment secrets",
            ),
            errors,
        )

    codex_guide = section_between(docs_source, "<h3>Codex", "<h3>Helper contract")
    if codex_guide is None:
        errors.append("site/docs/index.html: missing Codex agent guide")
    else:
        require_markers(
            codex_guide,
            "Codex agent guide",
            (
                "writes OSC directly to <code>/dev/tty</code>",
                "writes exactly <code>{}</code> to stdout",
                "If <code>/dev/tty</code> is unavailable",
                "exits successfully",
                "no stdin, prompt, transcript, or environment secrets",
            ),
            errors,
        )

    helper_contract = section_between(docs_source, "<h3>Helper contract</h3>", "</section>")
    if helper_contract is None:
        errors.append("site/docs/index.html: missing helper contract section")
    else:
        validate_helper_invocations(helper_contract, errors)
        require_markers(
            helper_contract,
            "helper contract",
            (
                "<code>working</code> → <code>3</code>",
                "<code>waiting</code> → <code>4</code>",
                "<code>failed</code> → <code>2</code>",
                "<code>completed</code> → <code>0</code>",
                "unknown mode",
                "unknown state",
                "extra argument",
                "returns nonzero",
                "no new dependencies",
            ),
            errors,
        )

    releases_source = page_sources.get((SITE / "releases" / "index.html").resolve(), "")
    if "0.1.2" not in releases_source or not re.search(r"\bbuild\s+9\b", releases_source, re.IGNORECASE):
        errors.append("site/releases/index.html: missing current version 0.1.2 build 9")
    if not re.search(r"beta.{0,240}superset of stable", releases_source, re.IGNORECASE | re.DOTALL):
        errors.append("site/releases/index.html: missing beta-superset copy")

    if errors:
        for error in errors:
            print(f"site-check: {error}", file=sys.stderr)
        print(f"site-check: FAIL ({len(errors)} error(s))", file=sys.stderr)
        return 1

    print(f"site-check: PASS ({len(html_files)} HTML pages)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

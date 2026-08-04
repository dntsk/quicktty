#!/usr/bin/env python3

from __future__ import annotations

import re
import sys
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

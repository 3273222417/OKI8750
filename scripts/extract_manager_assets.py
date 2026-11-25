#!/usr/bin/env python3
"""Extract valid rolling Manager APK links from a release page."""

from __future__ import annotations

import html
import re
import sys
from urllib.parse import unquote, urljoin, urlsplit


DOWNLOAD_LINK = re.compile(
    r"(?i)(?:https?://|/)[^\"'<>\s]+/-/(?:releases/download|git/raw)/[^\"'<>\s]+"
)
APK_NAME = re.compile(r"(?i)SukiSU_Nova_[^\"'< >\s]+-release\.apk")
RELEASE_APK = re.compile(r"(?i)release\.apk$")
EXCLUDED_APK = re.compile(r"(?i)(?:debug|spoofed)")


def extract_assets(document: str, base_url: str, expected_version: str) -> list[tuple[str, str]]:
    """Return APKs sorted by preferred architecture and then filename."""

    base = urlsplit(base_url)
    if base.scheme not in {"http", "https"} or not base.netloc:
        raise ValueError("base URL must be an absolute HTTP(S) URL")
    release_marker = "/-/releases/tag/"
    tree_marker = "/-/tree/"
    if release_marker in base.path:
        repository_path, ref = base.path.rsplit(release_marker, 1)
        if not repository_path or not ref or "/" in ref:
            raise ValueError("base URL has an invalid release tag path")
        prefixes = (f"{repository_path}/-/releases/download/{ref}/",)
        generated_prefix = None
    elif tree_marker in base.path:
        repository_path, ref = base.path.rsplit(tree_marker, 1)
        if not repository_path or not ref or "/" in ref:
            raise ValueError("base URL has an invalid tree ref path")
        prefixes = (f"{repository_path}/-/git/raw/{ref}/",)
        generated_prefix = prefixes[0] + "apks/"
    else:
        raise ValueError("base URL must point to a release tag or tree")

    # CNB embeds the release state as JSON in the page. Decode HTML entities
    # and escaped slashes before scanning both hrefs and embedded JSON paths.
    document = html.unescape(document).replace("\\/", "/")
    found: dict[tuple[str, str], int] = {}
    for match in DOWNLOAD_LINK.finditer(document):
        raw_url = match.group(0).rstrip(".,;:)]}\\")
        absolute = urljoin(base_url, raw_url)
        parsed = urlsplit(absolute)
        if parsed.scheme not in {"http", "https"} or parsed.netloc != base.netloc:
            continue
        if not any(parsed.path.startswith(prefix) for prefix in prefixes):
            continue
        name = unquote(parsed.path.rsplit("/", 1)[-1])
        if not RELEASE_APK.search(name) or EXCLUDED_APK.search(name):
            continue
        if not re.search(rf"_{re.escape(expected_version)}(?:-[A-Za-z0-9-]+)?-release\.apk$", name, re.I):
            continue
        if re.search(r"(?i)arm64-v8a", name):
            rank = 0
        elif re.search(r"(?i)universal", name):
            rank = 1
        else:
            continue
        found.setdefault((name, absolute), rank)

    # CNB tree pages expose file names but may omit raw links from the server
    # rendered HTML. Build the stable /-/git/raw URL from those names so a
    # page-only fallback still downloads the exact APK.
    if generated_prefix:
        for match in APK_NAME.finditer(document):
            name = match.group(0)
            if expected_version == "0" or not re.search(
                rf"_{re.escape(expected_version)}(?:-[A-Za-z0-9-]+)?-release\.apk$",
                name,
                re.I,
            ):
                continue
            if EXCLUDED_APK.search(name):
                continue
            if re.search(r"(?i)arm64-v8a", name):
                rank = 0
            elif re.search(r"(?i)universal", name):
                rank = 1
            else:
                continue
            found.setdefault((name, urljoin(base_url, generated_prefix + name)), rank)

    return [item for item, _ in sorted(found.items(), key=lambda entry: (entry[1], entry[0][0], entry[0][1]))]


def main() -> int:
    if len(sys.argv) != 3 or not re.fullmatch(r"[0-9]+", sys.argv[2]):
        print(f"usage: {sys.argv[0]} BASE_URL EXPECTED_VERSION", file=sys.stderr)
        return 2
    for name, url in extract_assets(sys.stdin.read(), sys.argv[1], sys.argv[2]):
        print(f"{name}\t{url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

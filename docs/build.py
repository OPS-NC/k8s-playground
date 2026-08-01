#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "markdown-it-py[linkify]>=3.0",
#   "mdit-py-plugins>=0.4",
#   "Pygments>=2.18",
# ]
# ///
"""
build.py — generates `docs/index.html` from the repository's READMEs.

A single, self-contained page: no CDN, no external asset, no server.
The markdown is converted at build time (markdown-it-py, CommonMark + tables) and
highlighted by Pygments; the embedded JS only handles navigation, search, language,
theme and the "copy" buttons.

Usage:
    ./docs/build.py                  # uv installs the deps on the fly (PEP 723)
    uv run docs/build.py --out /tmp/doc.html
    uv run docs/build.py --strict    # fails if an internal link does not resolve
    make docs

BILINGUAL: every page exists in two versions, in the SAME directory — English carries
the canonical name (`README.md`), French its mirror (`LISEZ-MOI.md`), see MIRRORS.
English is the default language; the sidebar's EN/FR selector switches the whole site
and the URL (`#fr/longhorn-readme`).

ADDING A PAGE: nothing to do, every `*.md` of the repository is discovered
automatically. Only the menu grouping and the emoji come from GROUPS / EMOJIS below;
an unknown directory falls into "Other".
"""

from __future__ import annotations

import argparse
import base64
import html
import json
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote

from markdown_it import MarkdownIt
from markdown_it.token import Token
from mdit_py_plugins.anchors import anchors_plugin
from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import get_lexer_by_name
from pygments.util import ClassNotFound

ROOT = Path(__file__).resolve().parent.parent

# Directories never explored (dependencies, artefacts, the generator's own output).
EXCLUDED_DIRS = {".git", ".vagrant", "node_modules", "docs", "_out", "lib"}

# Files never published, wherever they are. `CLAUDE.md` documents the repository for an
# assistant (internal conventions, checklists): it is a working note, not a page of the lab's
# documentation. Without this exclusion it would land in "Other".
EXCLUDED_FILES = {"CLAUDE.md"}

# Pages published EVEN IF git ignores them. Deliberately EMPTY: the page is published on
# GitHub Pages, where the build only has the versioned files. Forcing a local directory in
# would produce a local page different from the published one, and could expose a private
# configuration (a real domain, application keys). An add-on that must appear in the
# documentation therefore has to be versioned.
FORCE_INCLUDE: set[str] = set()

# --- Languages --------------------------------------------------------------
# name of the English (canonical) file -> name of its French mirror, same directory.
MIRRORS = {
    "README.md": "LISEZ-MOI.md",
}

# Pages that are ENGLISH ONLY by choice: no French mirror, and therefore no "not translated
# yet" badge — that would flag an oversight where there is a decision. Here EVERYTHING is
# translated: the empty set is therefore the right value, and the day a page has no mirror the
# "EN" badge will say so — that is intended.
NO_MIRROR: set[str] = set()
LANGS = ("en", "fr")
DEFAULT_LANG = "en"

# The project's public repository, pinned here rather than in the HTML template: it is the
# page's only external URL, and the reader of an offline copy must be able to find the source.
# The icon is an INLINE SVG (see repo_link): the page is self-contained, so no shields.io
# badge and no icon served from a CDN.
REPO_URL = "https://github.com/OPS-NC/k8s-playground"

# Project name: the site title, the sidebar brand, the browser-tab suffix and the prefix of
# the localStorage keys (language/theme). A single place to change.
PROJECT_NAME = "k8s-playground"
STORAGE_KEY = "k8s-playground-doc"
LOGO = "☸️"

# The "English · Français" banner put at the top of every file for GitHub readers. The HTML
# page has its own selector: we strip it.
RE_BANNER = re.compile(r"<!--\s*i18n\s*-->.*?<!--\s*/i18n\s*-->\s*", re.DOTALL)

# Interface labels. Every visible string of the template goes through here.
LABELS: dict[str, dict[str, str]] = {
    "en": {
        "search":       "Search…   /",
        "search_aria":  "Search a page",
        "toc":        "On this page",
        "copy":          "Copy",
        "copie":           "Copied!",
        "echec":           "Failed",
        "vers_clair":      "Switch to light theme",
        "vers_sombre":     "Switch to dark theme",
        "theme_aria":      "Documentation theme",
        "theme_clair":     "Light",
        "theme_sombre":    "Dark",
        "menu":            "Open the menu",
        "langue_aria":     "Documentation language",
        "source":          "Source:",
        "sections":        "sections",
        "badge":           "untracked",
        "badge_title":     "Not in git: local directory",
        "badge_lang":    "EN",
        "badge_lang_title": "Not translated yet — English page shown",
        "repo":           "GitHub repository",
        "subtitle":      "The Kubernetes layer shared by the Talos and kubeadm Vagrant labs — one tree, one argument.",
    },
    "fr": {
        "search":       "Rechercher…   /",
        "search_aria":  "Rechercher une page",
        "toc":        "Sur cette page",
        "copy":          "Copier",
        "copie":           "Copié !",
        "echec":           "Échec",
        "vers_clair":      "Passer en light",
        "vers_sombre":     "Passer en dark",
        "theme_aria":      "Thème de la documentation",
        "theme_clair":     "Clair",
        "theme_sombre":    "Sombre",
        "menu":            "Ouvrir le menu",
        "langue_aria":     "Langue de la documentation",
        "source":          "Source :",
        "sections":        "sections",
        "badge":           "non commité",
        "badge_title":     "Absent de git : dossier local",
        "badge_lang":    "EN",
        "badge_lang_title": "Pas encore traduit — page anglaise affichée",
        "repo":           "Dépôt GitHub",
        "subtitle":      "La couche Kubernetes commune aux labs Vagrant Talos et kubeadm — un seul tree, un argument.",
    },
}

# --- Menu layout ------------------------------------------------------------
# (titles per language, emoji, ENGLISH paths or directories, in display order)
GROUPS: list[tuple[dict[str, str], str, list[str]]] = [
    ({"en": "Start here",    "fr": "Démarrer"},          "☸️", ["README.md"]),
    ({"en": "Networking",    "fr": "Réseau"},            "🌐",
     ["cilium", "calico", "metallb", "envoy-gateway", "self-signed", "cert-manager"]),
    ({"en": "Storage",       "fr": "Stockage"},          "💾",
     ["longhorn", "local-path-storage", "minio-s3"]),
    ({"en": "Databases",     "fr": "Bases de données"},  "🗄️", ["cloudnative-pg"]),
    ({"en": "Identity",      "fr": "Identité"},          "🪪", ["keycloak", "dex"]),
    ({"en": "Secrets",       "fr": "Secrets"},           "🔐",
     ["vault-cluster", "vault-secret-operator"]),
    ({"en": "Observability", "fr": "Observabilité"},     "👁️",
     ["observability", "node-problem-detector", "chaos-kube"]),
    ({"en": "Security",      "fr": "Sécurité"},          "🛡️", ["kyverno", "trivy-operator"]),
    ({"en": "Demos",         "fr": "Démos"},             "🧪", ["argocd", "wordpress-example"]),
]
OTHERS = {"en": "Other", "fr": "Autres"}

EMOJIS: dict[str, str] = {
    "README.md":                             "☸️",
    "cilium/README.md":                      "🐝",
    "calico/README.md":                      "🐆",
    "metallb/README.md":                     "📢",
    "envoy-gateway/README.md":               "🚪",
    "self-signed/README.md":                 "🔏",
    "cert-manager/README.md":                "📜",
    "longhorn/README.md":                    "🐮",
    "local-path-storage/README.md":          "📁",
    "minio-s3/README.md":                    "🪣",
    "minio-s3/cluster/README.md":            "🧺",
    "vault-cluster/README.md":               "🔒",
    "vault-secret-operator/README.md":       "🔑",
    "vault-secret-operator/k8s/README.md":   "☸️",
    "vault-secret-operator/vault/README.md": "⚙️",
    "cloudnative-pg/README.md":              "🐘",
    "keycloak/README.md":                    "🛂",
    "dex/README.md":                         "🪪",
    "observability/README.md":               "📈",
    "node-problem-detector/README.md":       "🩺",
    "chaos-kube/README.md":                  "🐒",
    "kyverno/README.md":                     "⚖️",
    "trivy-operator/README.md":              "🔎",
    "argocd/README.md":                      "🐙",
    "wordpress-example/README.md":           "📝",
}

# Callouts: a marker at the start of a blockquote picks the colour. Both languages share the
# table, hence the FR *and* EN markers.
CALLOUTS: list[tuple[str, tuple[str, ...]]] = [
    ("danger", ("⚠️", "🚨", "❌", "attention", "danger", "jamais", "ne pas", "ne jamais",
                "never", "do not", "don't", "warning")),
    ("tip", ("💡", "✅", "🎯", "astuce", "conseil", "bon à savoir",
                "tip", "good to know")),
    ("info",   ("ℹ️", "📌", "📝", "🔍", "nb ", "nb :", "note", "remarque", "réf",
                "ref", "reminder")),
]


# ===========================================================================
#  Page discovery
# ===========================================================================

def git(*args: str) -> str:
    """Calls git in the repository; an empty string if git is missing or errors out."""
    try:
        return subprocess.run(["git", "-C", str(ROOT), *args],
                              capture_output=True, text=True, check=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def git_ignored(paths: list[str]) -> set[str]:
    """Sous-ensemble des paths que git ignore (ex. le projet local proxmox/).

    We document the repository, not local working directories — but a merely
    *untracked* file is still published, with a badge.
    """
    if not paths:
        return set()
    try:
        res = subprocess.run(["git", "-C", str(ROOT), "check-ignore", "--stdin"],
                             input="\n".join(paths), capture_output=True, text=True,
                             check=False)
        return set(res.stdout.split())      # rc=1 when nothing is ignored: expected
    except FileNotFoundError:
        return set()


def read_page(path: str) -> str:
    """Text of a page, with the language banner stripped."""
    return RE_BANNER.sub("", (ROOT / path).read_text(encoding="utf-8"), count=1).lstrip()


def discover() -> list[dict]:
    """Lists the repository's documents (one entry per EN/FR pair), following GROUPS."""
    tracked = set(git("ls-files", "*.md").split())
    found = sorted(
        p.relative_to(ROOT).as_posix()
        for p in ROOT.rglob("*.md")
        if not (EXCLUDED_DIRS & set(p.relative_to(ROOT).parts))
        and p.name not in EXCLUDED_FILES
    )
    exclus = git_ignored(found) - FORCE_INCLUDE
    remaining = [c for c in found if c not in exclus]

    # pairs every English page with its French mirror, which leaves the list: it is not
    # one more document, it is the other version of the same document.
    mirror_of: dict[str, str] = {}
    for path in list(remaining):
        p = Path(path)
        if p.name in MIRRORS:
            fr = (p.parent / MIRRORS[p.name]).as_posix()
            if fr in remaining:
                mirror_of[path] = fr
                remaining.remove(fr)

    docs: list[dict] = []

    def take(path: str, group: dict[str, str], default_emoji: str) -> None:
        remaining.remove(path)
        fr = mirror_of.get(path, path)      # sans mirror : le FR retombe sur l'EN
        docs.append({
            "path": path,                   # path canonique (anglais)
            "paths": {"en": path, "fr": fr},
            "group": group,
            "emoji": EMOJIS.get(path, default_emoji),
            # sans git on ne peut rien affirmer : on ne signale rien
            "tracked": path in tracked or not tracked,
        })

    for group, emoji, entries in GROUPS:
        for entry in entries:
            if entry.endswith(".md"):
                if entry in remaining:
                    take(entry, group, emoji)
            else:  # un dossier : ses pages canoniques, la moins profonde d'abord
                for path in sorted((c for c in list(remaining)
                                      if c.startswith(entry + "/")
                                      and Path(c).name in MIRRORS),
                                     key=lambda c: (c.count("/"), c)):
                    take(path, group, emoji)

    for path in list(remaining):     # nothing disappears from the menu
        take(path, OTHERS, "📄")
    return docs


# ===========================================================================
#  Conversion markdown → HTML
# ===========================================================================

# Leading emoji of a title: the READMEs start with an emoji (a style contract), and the
# generator adds one too. Without splitting them apart they would show up twice.
# The repetition tolerates spaces, so that a title carrying several of them
# (`# 🏠 🐧 Vagrant-KubeADM`) keeps them all grouped in the header.
RE_LEADING_EMOJI = re.compile(
    r"^((?:[\U0001F000-\U0001FAFF←-⇿⌀-➿⬀-⯿]"
    r"[︎️‍]*[ \t]*)+)"
)


def split_emoji(title: str) -> tuple[str, str]:
    """Splits off the leading emoji (or emojis) of a title: (emoji, rest)."""
    m = RE_LEADING_EMOJI.match(title)
    return (m.group(1).strip(), title[m.end():].lstrip()) if m else ("", title)


def strip_markdown(text: str) -> str:
    """Plain text of a title (menu, browser tab, search): the markup is stripped."""
    text = re.sub(r"`([^`]*)`", r"\1", text)
    text = re.sub(r"\*\*([^*]*)\*\*", r"\1", text)
    text = re.sub(r"\*([^*]*)\*", r"\1", text)
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    return text.strip()


def slug(title: str) -> str:
    """A GitHub-style slug: lowercase, accents kept, punctuation and emoji removed.

    The repository's headings start with an emoji (`## 🚑 7. Troubleshooting`): without
    the trailing `strip("-")` the slug would inherit a leading dash.
    """
    slug = "".join(c for c in title.lower() if c.isalnum() or c in " -_")
    return re.sub(r"[\s-]+", "-", slug).strip("-_")


def make_converter() -> MarkdownIt:
    """CommonMark + tables + raw HTML (`<details>`) + anchors on the headings."""
    md = (
        MarkdownIt("commonmark", {"html": True, "linkify": True, "breaks": False})
        .enable(["table", "strikethrough"])
        .use(anchors_plugin, max_level=4, permalink=True, permalinkSymbol="#",
             permalinkSpace=False, slug_func=slug)
    )
    md.add_render_rule("fence", _render_fence)
    return md


def _render_fence(self, tokens: list[Token], idx: int, options, env) -> str:
    """Code block: Pygments highlighting + a copy button + a language label.

    The button carries no label at build time: the JS sets it in the active language,
    otherwise switching FR/EN would leave "Copier" strings in the English page.
    """
    token_ = tokens[idx]
    # `token_.info` is " " (and not "") when the block's closing fence carries a trailing
    # space — a string of spaces is TRUTHY, so the old `if token_.info` test passed, and
    # `"".split()[0]` raised an IndexError that killed the whole generation.
    # We split first and index afterwards: no branch left to lie to us.
    parts = (token_.info or "").strip().split()
    language = parts[0].lower() if parts else ""
    try:
        body = highlight(token_.content, get_lexer_by_name(language or "text"),
                          HtmlFormatter(nowrap=True))
    except ClassNotFound:
        body = html.escape(token_.content, quote=False)
    label = {"bash": "shell", "sh": "shell", "yml": "yaml", "": "text"}.get(language, language)
    return (
        f'<figure class="code-block" data-language="{html.escape(label, quote=True)}">'
        f'<button class="copy" type="button"></button>'
        f'<pre><code>{body}</code></pre></figure>'
    )


def callout_kind(text: str) -> str:
    """Picks a callout's style from the beginning of its text."""
    debut = text.lstrip().lower()[:48]
    for name, markers in CALLOUTS:
        if any(m in debut for m in markers):
            return name
    return "plain"


def prepare(tokens_: list[Token]) -> tuple[str | None, list[dict]]:
    """Annotates the tokens (callouts, scrollable tables) and collects the toc.

    Returns (H1 title, toc); the H1 is removed from the body, it becomes the page header.
    """
    h1_title: str | None = None
    toc: list[dict] = []

    for i, token_ in enumerate(tokens_):
        if token_.type == "blockquote_open":
            # the blockquote's first inline determines the callout colour
            first_inline = next((t for t in tokens_[i + 1:i + 6] if t.type == "inline"), None)
            token_.attrJoin("class", f"callout callout-{callout_kind(first_inline.content if first_inline else '')}")

        elif token_.type == "heading_open":
            inline = tokens_[i + 1]
            text = re.sub(r"\s*#\s*$", "", inline.content).strip()
            if token_.tag == "h1" and h1_title is None:
                h1_title = text
                # neutralise the H1: it is re-displayed in the page header
                token_.type, token_.tag, token_.hidden = "html_block", "", True
                token_.content = ""
                inline.children, inline.content = [], ""
                tokens_[i + 2].hidden = True
            elif token_.tag in ("h2", "h3"):
                toc.append({"level": token_.tag, "title": text,
                                 "slug": token_.attrGet("id") or ""})

    return h1_title, toc


def convert(md: MarkdownIt, page: dict) -> dict:
    """Renders a page and returns everything the template needs.

    The title comes in three shapes: the emoji (split off the H1), the formatted title
    (markdown `code` becomes a real <code>) and the plain title (menu, browser tab,
    search).
    """
    tokens_ = md.parse(page["text"])
    raw_title, toc = prepare(tokens_)
    body = md.renderer.render(tokens_, md.options, {})

    # tables: wrapped so they can scroll horizontally on mobile
    body = body.replace("<table>", '<div class="table-scroll"><table>')
    body = body.replace("</table>", "</table></div>")
    # the anchors point at the internal route #<page>/<section>
    body = re.sub(r'(class="header-anchor" href=")#',
                   rf"\1#{page['id']}/", body)

    raw_title = raw_title or Path(page["path"]).parent.name or page["path"]
    emoji, raw_title = split_emoji(raw_title)
    return {
        "body": body,
        "toc": toc,
        # the README's emoji wins; otherwise the one from the EMOJIS table / the group
        "emoji": emoji or page["emoji"],
        "title_html": md.renderInline(raw_title),
        "title_text": strip_markdown(raw_title),
    }


# ===========================================================================
#  Liens internes : `foo/README.md#slug` → route `#en/foo-readme/slug`
# ===========================================================================

RE_MD_LINK = re.compile(r'href="([^":#?]+\.md)(#[^"]*)?"')
RE_HEADING_ID = re.compile(r'<h[1-6][^>]*\sid="([^"]+)"')


def resolve_links(rendered: dict, index: dict[str, dict[str, str]],
             anchors: dict[str, set[str]], warnings: list[str]) -> str:
    """Rewrites the body's `*.md` links into internal routes of the single page.

    Without this pass, `[cilium/](../cilium/README.md)` would stay a *file* link:
    *file_* : cliquable sur GitHub, mort sur GitHub Pages. Le fragment est
    clickable on GitHub, dead on GitHub Pages. The fragment is reconciled with the
    anchors actually generated on the target side — GitHub anchors keep the leading dash
    """
    base = Path(rendered["path"]).parent
    table = index[rendered["lang"]]

    def replace(m: re.Match[str]) -> str:
        # `Path(target)` is RELATIVE: `.resolve()` resolved it against the process' cwd
        # and not against ROOT. The guard therefore tested one path while `.resolve()`
        # computed another, hence an UNCAUGHT `ValueError: not in the subpath of` that
        # crashed the whole generation — as soon as build.py was run from a directory
        # other than the root, or as soon as a link left the repository
        # (`../neighbour/README.md`), in which case `--strict` crashed instead of
        # reporting the broken link cleanly.
        # We resolve explicitly from ROOT, and only convert when the target stays inside
        # the repository. `unquote` to stay consistent with the fragment handling below
        # (an accented file name arrives percent-encoded).
        target = (base / unquote(m.group(1))).as_posix()
        absolu = (ROOT / target).resolve()
        if absolu.is_relative_to(ROOT):
            target = absolu.relative_to(ROOT).as_posix()
        target_id = table.get(target)
        if not target_id:
            warnings.append(f"{rendered['path']} → {m.group(1)} (page absente de la doc)")
            return m.group(0)
        # markdown-it percent-encodes non-ASCII characters: the French anchors
        # (`#-accès-distant-…`) arrive here as `%C3%A8`, to be decoded before comparison.
        frag = unquote((m.group(2) or "")[1:])
        if frag:
            for essai in (frag, frag.strip("-_"), slug(frag)):
                if essai in anchors[target_id]:
                    frag = essai
                    break
            else:
                warnings.append(f"{rendered['path']} → {m.group(1)}#{frag} (slug inconnue)")
                frag = ""
        return f'href="#{target_id}{"/" + frag if frag else ""}"'

    return RE_MD_LINK.sub(replace, rendered["body"])


RE_IMG_SRC = re.compile(r'(<img\b[^>]*?\bsrc=")([^"]+)(")', re.IGNORECASE)
MIMES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
         ".gif": "image/gif", ".svg": "image/svg+xml", ".webp": "image/webp"}


def inline_images(body: str, path: str, warnings: list[str]) -> str:
    """Converts the body's LOCAL images into base64 data: URIs.

    The path written in the markdown is relative to the source file, so it only works for
    GitHub; it would not resolve from the single page, which lives elsewhere
    (`docs/index.html` locally, `_site/index.html` in CI). Rather than copying the files
    next to the output, we embed them: the page stays ONE self-contained file, portable and
    readable offline — the promise kept everywhere else in this generator.

    Corollary: keep the images LIGHT, they inflate the page by roughly 4/3 of their own
    weight (the base64 overhead).
    """
    base = Path(path).parent

    def replace(m: re.Match[str]) -> str:
        src = m.group(2)
        if src.startswith(("http://", "https://", "data:", "//")):
            return m.group(0)                      # ressource externe : intacte
        file_ = (ROOT / base / unquote(src)).resolve()
        if not file_.is_file():
            warnings.append(f"{path} → {src} (image introuvable)")
            return m.group(0)
        mime = MIMES.get(file_.suffix.lower())
        if mime is None:
            warnings.append(f"{path} → {src} (unsupported image format)")
            return m.group(0)
        data = base64.b64encode(file_.read_bytes()).decode("ascii")
        return f"{m.group(1)}data:{mime};base64,{data}{m.group(3)}"

    return RE_IMG_SRC.sub(replace, body)


# ===========================================================================
#  Feuille de style
# ===========================================================================

def pygments_css() -> str:
    """Pygments highlighting themes, aligned with the palette's logic.

    Same rule as the CSS variables: LIGHT is the default, dark only applies if the reader
    explicitly chose it. Without this, the code blocks would stay dark-themed on a light
    page.
    """
    def defs(style: str, selector: str) -> str:
        try:
            return HtmlFormatter(style=style).get_style_defs(selector)
        except ClassNotFound:
            return HtmlFormatter().get_style_defs(selector)

    dark = defs("github-dark", ':root[data-theme="dark"] .code-block pre')
    light = defs("friendly", ':root:not([data-theme="dark"]) .code-block pre')
    return (
        f"{dark}\n{light}\n"
        # the blocks' background comes from our variables, not from the Pygments theme
        ".code-block pre{background:none!important}\n"
    )


DARK_PALETTE = """
  --bg:#15161a; --bg-2:#1c1e23; --bg-3:#24272d;
  --text:#e9eaec; --text-2:#a5a9b2; --text-3:#7a7f88;
  --border:#2b2e35; --borderer-strong:#3a3e46;
  --accent:#74a0f7; --accent-soft:#1b2436;
  --code-bg:#1a1c20;
  --danger:#f28b80; --danger-bg:#2a1c1b;
  --tip:#6bc99a; --tip-bg:#14231f;
  --info:#74a0f7;   --info-bg:#171f2e;
  --shadow:0 1px 2px rgba(0,0,0,.3),0 4px 14px rgba(0,0,0,.24);
"""

CSS = """
*,*::before,*::after{box-sizing:border-box}
:root{
  --bg:#fdfdfc; --bg-2:#f5f5f3; --bg-3:#ebebe7;
  --text:#1b1c1f; --text-2:#5b5e65; --text-3:#8a8e95;
  --border:#e3e3df; --borderer-strong:#cecec8;
  --accent:#2f6feb; --accent-soft:#eaf1fe;
  --code-bg:#f8f8f6;
  --danger:#c4342b; --danger-bg:#fdf1f0;
  --tip:#177f50; --tip-bg:#eff8f3;
  --info:#2f6feb;   --info-bg:#eff4fe;
  --shadow:0 1px 2px rgba(20,20,20,.05),0 4px 12px rgba(20,20,20,.04);
  --mono:ui-monospace,"SF Mono","JetBrains Mono","Cascadia Code",Menlo,Consolas,monospace;
  --sans:system-ui,-apple-system,"Segoe UI",Inter,Roboto,"Helvetica Neue",sans-serif;
  --menu:290px; --toc:15.5rem; --text-wide:52rem;
}
/* CLAIR PAR DÉFAUT : la palette claire ci-dessus est celle qui s'applique, et le
   dark only kicks in if the reader explicitly asked for it through the toggle.
   So we do NOT listen to prefers-color-scheme — that is a deliberate choice. */
:root[data-theme="dark"]{__DARK__}
html{scroll-behavior:smooth;-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--text);font:16px/1.7 var(--sans);
  -webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline;text-underline-offset:3px}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:4px}

/* ---------- structure ----------
   The toc is a REAL grid column (and not a `fixed` element compensated by a margin):
   otherwise, reserving its space with `margin-right` overrides the content's
   `margin:0 auto` and the remaining `margin-left:auto` shifts all the text to the
   right on large screens. */
.wrapper{display:grid;grid-template-columns:var(--menu) minmax(0,1fr);
  min-height:100vh;align-items:start}
.menu{position:sticky;top:0;height:100vh;overflow-y:auto;background:var(--bg-2);
  border-right:1px solid var(--border);padding:1.4rem 0 3rem;scrollbar-width:thin}
/* `width:100%` est INDISPENSABLE avec `margin-inline:auto` : des marges auto sur un
   element disable stretching along the track, the element is then sized as fit-content
   — so capped at its `max-width` (941px) whatever the track's real width. Below a
   941px viewport it overflowed to the right, with a global horizontal scroll. With
   avec un scroll horizontal global. Avec `width:100%` il suit la piste, et les
   marges auto ne recentrent que lorsqu'il reste de la place. */
.content{min-width:0;width:100%;padding:2.4rem clamp(1.2rem,4vw,3.4rem) 6rem;
  max-width:calc(var(--text-wide) + 6.8rem);margin-inline:auto}

/* ---------- menu ---------- */
/* Brand in a COLUMN: the repo badge on its own line. Placed at the end of the title
   line, it shrank it enough to break "Vagrant-KubeADM" and the timestamp in two
   (menu at 290px). */
.brand{display:flex;flex-direction:column;align-items:flex-start;gap:.6rem;
  padding:0 1.3rem 1.1rem;font-weight:650;letter-spacing:-.01em}
.brand-title{display:flex;align-items:center;gap:.65rem}
.brand .logo{font-size:1.5rem;line-height:1}
.brand small{display:block;font-weight:450;color:var(--text-3);font-size:.74rem;
  letter-spacing:0;font-family:var(--mono)}
/* Repo badge, at the top of the left menu under the title.
   `currentColor` on the SVG => it follows the light/dark theme. */
.brand .repo{display:inline-flex;align-items:center;gap:.3rem;align-self:center;
  padding:.2rem .45rem;border:1px solid var(--borderer-strong);border-radius:6px;
  color:var(--text-2);font-size:.72rem;font-weight:600;letter-spacing:0}
.brand .repo:hover{color:var(--text);background:var(--bg-3);
  border-color:var(--text-3);text-decoration:none}
.brand .repo svg{flex:0 0 14px;width:14px;height:14px;fill:currentColor}
.search{padding:0 1.1rem 1rem}
.search input{width:100%;padding:.5rem .7rem;border:1px solid var(--borderer-strong);
  border-radius:8px;background:var(--bg);color:var(--text);font:inherit;font-size:.87rem}
.group > h2{margin:0;padding:.85rem 1.35rem .35rem;font-size:.69rem;font-weight:650;
  text-transform:uppercase;letter-spacing:.09em;color:var(--text-3)}
.menu a{display:flex;gap:.55rem;align-items:baseline;padding:.34rem 1.35rem;
  color:var(--text-2);font-size:.89rem;border-left:2px solid transparent}
.menu a:hover{color:var(--text);background:var(--bg-3);text-decoration:none}
.menu a.active{color:var(--accent);background:var(--accent-soft);
  border-left-color:var(--accent);font-weight:550}
.menu a .emo{flex:0 0 1.15rem;font-size:.95rem}
.menu a .txt{min-width:0}
.menu a .path{display:block;font-size:.7rem;color:var(--text-3);
  font-family:var(--mono);word-break:break-all;line-height:1.35}
.badge{display:inline-block;margin-left:.35rem;padding:0 .34rem;border-radius:4px;
  background:var(--danger-bg);color:var(--danger);font-size:.63rem;font-weight:650;
  text-transform:uppercase;letter-spacing:.04em;vertical-align:middle}
.badge-lang{background:var(--info-bg);color:var(--info)}

/* ---------- language selector ---------- */
.langs{display:flex;gap:.3rem;padding:0 1.1rem 1rem}
.langs button{flex:1;padding:.32rem 0;border:1px solid var(--borderer-strong);border-radius:7px;
  background:var(--bg);color:var(--text-2);font:650 .74rem/1.45 var(--sans);
  letter-spacing:.05em;cursor:pointer;transition:color .12s,border-color .12s}
.langs button:hover{color:var(--accent);border-color:var(--accent)}
/* Theme selector: same template as .langs, right below it. */
.themes{display:flex;gap:.3rem;padding:0 1.1rem .9rem}
.themes button{flex:1;padding:.32rem 0;border:1px solid var(--borderer-strong);border-radius:7px;
  background:var(--bg);color:var(--text-2);font-size:.78rem;cursor:pointer}
.themes button:hover{color:var(--accent);border-color:var(--accent)}
.themes button[aria-pressed="true"]{background:var(--accent-soft);color:var(--accent);
  border-color:var(--accent)}
.langs button[aria-pressed="true"]{background:var(--accent-soft);color:var(--accent);
  border-color:var(--accent)}

/* ---------- page header ---------- */
.breadcrumb{display:flex;align-items:center;gap:.45rem;flex-wrap:wrap;margin-bottom:.55rem;
  font:.77rem/1.5 var(--mono);color:var(--text-3)}
.page > h1{margin:.1rem 0 .35rem;font-size:clamp(1.7rem,3.4vw,2.3rem);line-height:1.18;
  letter-spacing:-.022em;font-weight:680}
.page > h1 .emo{margin-right:.45rem}
/* `code` inside a title: kept monospace but without the inline-code frame, which would
   qui alourdirait un title de 2rem. */
.page > h1 code{font-size:.86em;font-weight:640;background:var(--bg-3);
  border:1px solid var(--border);border-radius:7px;padding:.06em .3em}
.page h2 code,.page h3 code,.page h4 code{font-size:.9em;font-weight:inherit}
.subtitle{margin:0 0 2.2rem;color:var(--text-2);font-size:1.02rem;max-width:44rem}
.subtitle > p{margin:0 0 .4rem}

/* ---------- content ---------- */
.page h2,.page h3,.page h4{letter-spacing:-.015em;line-height:1.3;scroll-margin-top:1.5rem}
.page h2{margin:2.9rem 0 .9rem;padding-bottom:.42rem;font-size:1.4rem;font-weight:660;
  border-bottom:1px solid var(--border)}
.page h3{margin:2.1rem 0 .7rem;font-size:1.12rem;font-weight:640}
.page h4{margin:1.6rem 0 .5rem;font-size:1rem;font-weight:640;color:var(--text-2)}
.page p{margin:0 0 1.05rem}
.page ul,.page ol{margin:0 0 1.1rem;padding-left:1.4rem}
.page li{margin:.28rem 0}
.page li > p{margin:.3rem 0}
.page li::marker{color:var(--text-3)}
.page hr{margin:2.6rem 0;border:0;border-top:1px solid var(--border)}
.page strong{font-weight:640;color:var(--text)}
.page img{max-width:100%;height:auto}
.header-anchor{margin-left:.4rem;color:var(--text-3);opacity:0;font-weight:400;
  text-decoration:none;transition:opacity .12s}
h2:hover>.header-anchor,h3:hover>.header-anchor,h4:hover>.header-anchor{opacity:1}

/* ---------- code ---------- */
code{font-family:var(--mono);font-size:.875em}
:not(pre) > code{background:var(--bg-3);color:var(--text);padding:.12em .38em;
  border-radius:5px;border:1px solid var(--border)}
.code-block{position:relative;margin:0 0 1.25rem;background:var(--code-bg);
  border:1px solid var(--border);border-radius:10px;box-shadow:var(--shadow);overflow:hidden}
.code-block::before{content:attr(data-language);position:absolute;top:0;right:0;
  padding:.18rem .6rem;font:600 .65rem/1.5 var(--mono);letter-spacing:.06em;
  text-transform:uppercase;color:var(--text-3);background:var(--bg-3);
  border-left:1px solid var(--border);border-bottom:1px solid var(--border);
  border-bottom-left-radius:8px}
.code-block pre{margin:0;padding:1.55rem 1.05rem 1.05rem;overflow-x:auto;
  font-family:var(--mono);font-size:.845rem;line-height:1.62;tab-size:2}
.code-block code{white-space:pre}
.copy{position:absolute;top:2.35rem;right:.55rem;z-index:2;padding:.26rem .55rem;
  border:1px solid var(--borderer-strong);border-radius:6px;background:var(--bg);
  color:var(--text-2);font:550 .72rem/1 var(--sans);cursor:pointer;opacity:0;
  transition:opacity .13s,color .13s}
.code-block:hover .copy,.copy:focus-visible{opacity:1}
.copy:hover{color:var(--accent);border-color:var(--accent)}
.copy.ok{color:var(--tip);border-color:var(--tip)}

/* ---------- encarts (citations) ---------- */
.callout{margin:0 0 1.25rem;padding:.85rem 1.1rem;border-left:3px solid var(--borderer-strong);
  border-radius:0 8px 8px 0;background:var(--bg-2);color:var(--text-2)}
.callout > :last-child{margin-bottom:0}
.callout .code-block{margin:.75rem 0 .35rem;box-shadow:none}
.callout-danger{border-left-color:var(--danger);background:var(--danger-bg)}
.callout-tip{border-left-color:var(--tip);background:var(--tip-bg)}
.callout-info{border-left-color:var(--info);background:var(--info-bg)}

/* ---------- tableaux ---------- */
.table-scroll{overflow-x:auto;margin:0 0 1.3rem;border:1px solid var(--border);
  border-radius:10px;box-shadow:var(--shadow)}
table{width:100%;border-collapse:collapse;font-size:.895rem}
th,td{padding:.58rem .85rem;text-align:left;vertical-align:top;
  border-bottom:1px solid var(--border)}
th{background:var(--bg-2);font-weight:640;font-size:.78rem;text-transform:uppercase;
  letter-spacing:.05em;color:var(--text-2);white-space:nowrap}
tbody tr:last-child td{border-bottom:0}
tbody tr:hover{background:var(--bg-2)}

/* ---------- details ---------- */
details{margin:0 0 1.3rem;border:1px solid var(--border);border-radius:10px;
  background:var(--bg-2);overflow:hidden}
details > summary{padding:.75rem 1.05rem;font-weight:600;cursor:pointer;list-style:none;
  display:flex;align-items:center;gap:.5rem}
details > summary::-webkit-details-marker{display:none}
details > summary::before{content:"›";display:inline-block;font-size:1.15rem;
  color:var(--text-3);transition:transform .15s}
details[open] > summary::before{transform:rotate(90deg)}
details > summary:hover{background:var(--bg-3)}
details > :not(summary){margin-left:1.05rem;margin-right:1.05rem}
details > :not(summary):last-child{margin-bottom:1.05rem}

/* ---------- toc de droite ---------- */
.toc{display:none;position:sticky;top:2.4rem;max-height:calc(100vh - 5rem);
  overflow-y:auto;padding:0 1.4rem 2rem 0;font-size:.82rem}
.toc h2{margin:0 0 .5rem;font-size:.69rem;font-weight:650;text-transform:uppercase;
  letter-spacing:.09em;color:var(--text-3)}
.toc a{display:block;padding:.18rem 0 .18rem .7rem;color:var(--text-2);
  border-left:2px solid var(--border);line-height:1.45}
.toc a:hover{color:var(--text);text-decoration:none}
.toc a.active{color:var(--accent);border-left-color:var(--accent);font-weight:550}
.toc a.n3{padding-left:1.5rem;font-size:.78rem}
@media (min-width:1500px){
  .wrapper{grid-template-columns:var(--menu) minmax(0,1fr) var(--toc)}
  .toc{display:block}
}

/* ---------- topbar mobile ---------- */
.topbar{display:none;position:sticky;top:0;z-index:20;align-items:center;gap:.7rem;
  padding:.6rem .9rem;background:var(--bg);border-bottom:1px solid var(--border)}
.topbar .langs{padding:0;margin-left:auto;gap:.25rem}
.topbar .langs button{padding:.3rem .45rem;min-width:2.3rem}
.icon-button{display:grid;place-items:center;width:2.1rem;height:2.1rem;flex:0 0 auto;
  border:1px solid var(--borderer-strong);border-radius:8px;background:var(--bg);
  color:var(--text-2);font-size:1rem;cursor:pointer}
.icon-button:hover{color:var(--accent);border-color:var(--accent)}
.theme-floating{position:fixed;bottom:1.1rem;right:1.1rem;z-index:30;box-shadow:var(--shadow)}
.overlay{position:fixed;inset:0;z-index:35;background:rgba(0,0,0,.45);display:none}
@media (max-width:1000px){
  /* minmax(0,1fr) et NON 1fr : une piste `1fr` garde un min-width:auto implicite,
     so it refuses to go below the intrinsic width of its content. Wide code blocks and
     tables then widened the column beyond the viewport => all the text overflowed to the
     right, with a global horizontal scroll.
     Desktop already used minmax(0,1fr); only mobile had been forgotten. */
  .wrapper{grid-template-columns:minmax(0,1fr)}
  .topbar{display:flex}
  .menu{position:fixed;inset:0 auto 0 0;width:min(86vw,var(--menu));z-index:40;
    transform:translateX(-100%);transition:transform .2s ease;box-shadow:var(--shadow)}
  .menu.open{transform:none}
  .overlay.open{display:block}
  .content{padding:1.6rem 1.15rem 5rem}
  .theme-floating{display:none}
}
@media print{
  .menu,.toc,.topbar,.copy,.theme-floating,.header-anchor,.overlay,
  .langs,.themes{display:none!important}
  .wrapper{grid-template-columns:minmax(0,1fr)}
  .page{display:block!important;page-break-after:always}
  .code-block,.table-scroll{box-shadow:none}
}
.page{display:none}
.page.visible{display:block}
.footer{margin-top:4rem;padding-top:1.3rem;border-top:1px solid var(--border);
  color:var(--text-3);font-size:.79rem;display:flex;justify-content:space-between;
  gap:1rem;flex-wrap:wrap}
""".replace("__DARK__", DARK_PALETTE)


JS = r"""
(() => {
  const LANGS = __LANGUES__;
  const LABELS = __LIBELLES__;
  const DEFAULT = __DEFAUT__;

  const pages = [...document.querySelectorAll('.page')];
  const links = [...document.querySelectorAll('.menu a[data-page]')];
  const menu  = document.querySelector('.menu');
  const overlay = document.querySelector('.overlay');
  const box = document.querySelector('.toc');
  const field = document.querySelector('.search input');
  let observer = null;

  /* --- language: remembered, but always derived from the displayed page --- */
  const LANG_KEY = __CLE__ + '-lang';
  const storedLang = localStorage.getItem(LANG_KEY);
  let lang = LANGS.includes(storedLang) ? storedLang : DEFAULT;
  const words = () => LABELS[lang];

  const updateLang = (next_) => {
    lang = next_;
    localStorage.setItem(LANG_KEY, lang);
    document.documentElement.lang = lang;
    const m = words();
    document.querySelectorAll('.tree').forEach(a => { a.hidden = a.dataset.lang !== lang; });
    document.querySelectorAll('.langs button').forEach(b => {
      b.setAttribute('aria-pressed', String(b.dataset.lang === lang));
    });
    field.placeholder = m.search;
    field.setAttribute('aria-label', m.search_aria);
    document.querySelectorAll('[data-menu-toggle]').forEach(b => b.setAttribute('aria-label', m.menu));
    document.querySelectorAll('.langs').forEach(g => g.setAttribute('aria-label', m.langue_aria));
    document.querySelectorAll('[data-repo]').forEach(a => {
      a.setAttribute('aria-label', m.repo); a.setAttribute('title', m.repo);
    });
    document.querySelectorAll('.copy').forEach(b => { b.textContent = m.copy; });
    updateTheme();
    if (box.firstElementChild) box.firstElementChild.textContent = m.toc;
  };

  /* --- toc of the displayed page + highlight while reading --- */
  const buildToc = (page) => {
    const headings = [...page.querySelectorAll('h2[id],h3[id]')];
    observer?.disconnect();
    if (headings.length < 3) { box.innerHTML = ''; return; }
    box.innerHTML = `<h2>${words().toc}</h2>` + headings.map(h => {
      const label = h.textContent.replace(/#$/, '').trim();
      return `<a href="#${page.id}/${h.id}" data-pour="${h.id}"
                 class="${h.tagName === 'H3' ? 'n3' : ''}">${label}</a>`;
    }).join('');
    const anchors = new Map([...box.querySelectorAll('a')].map(a => [a.dataset.pour, a]));
    observer = new IntersectionObserver(entries => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        anchors.forEach(a => a.classList.remove('active'));
        anchors.get(e.target.id)?.classList.add('active');
      }
    }, { rootMargin: '-8% 0px -80% 0px' });
    headings.forEach(h => observer.observe(h));
  };

  /* --- routage : #<lang>/<page>/<section> ---
     The old format (#<page>/<section>, without the language) is still accepted: links
     already shared keep opening the right page, in the current language. */
  const show = (id, section) => {
    const target = pages.find(p => p.id === id)
               ?? pages.find(p => p.dataset.lang === lang)
               ?? pages[0];
    if (target.dataset.lang !== lang) updateLang(target.dataset.lang);
    pages.forEach(p => p.classList.toggle('visible', p === target));
    links.forEach(a => {
      const active = a.dataset.page === target.id;
      a.classList.toggle('active', active);
      active ? a.setAttribute('aria-current', 'page') : a.removeAttribute('aria-current');
    });
    buildToc(target);
    document.title = target.dataset.title + ' · ' + __NOM__;
    const h = section && target.querySelector('[id="' + CSS.escape(section) + '"]');
    h ? h.scrollIntoView() : window.scrollTo(0, 0);
  };
  const route = () => {
    const parts = decodeURIComponent(location.hash.slice(1)).split('/').filter(Boolean);
    return LANGS.includes(parts[0])
      ? { id: parts.slice(0, 2).join('/'), section: parts[2] }
      : { id: parts.length ? lang + '/' + parts[0] : '', section: parts[1] };
  };
  const router = () => { const r = route(); show(r.id, r.section); };

  /* --- language toggle: same page, other version --- */
  document.querySelectorAll('.langs button').forEach(b => b.addEventListener('click', () => {
    const next_ = b.dataset.lang;
    if (next_ === lang) return;
    const current = pages.find(p => p.classList.contains('visible'));
    const section = route().section;
    updateLang(next_);
    location.hash = '#' + next_ + '/' + (current?.dataset.doc ?? '')
                  + (section ? '/' + section : '');
    router();   /* if the hash did not change (missing page), render anyway */
  }));

  /* --- search (title, path, sections) ; « / » pour cibler le field --- */
  field.addEventListener('input', () => {
    const q = field.value.trim().toLowerCase();
    links.forEach(a => { a.hidden = !!q && !a.dataset.search.includes(q); });
    document.querySelectorAll('.group').forEach(g => {
      g.hidden = ![...g.querySelectorAll('a')].some(a => !a.hidden);
    });
  });
  document.addEventListener('keydown', e => {
    if (e.key === '/' && document.activeElement !== field) { e.preventDefault(); field.focus(); }
    else if (e.key === 'Escape' && document.activeElement === field) {
      field.value = ''; field.dispatchEvent(new Event('input')); field.blur();
    }
  });

  /* --- copy un bloc de code --- */
  document.addEventListener('click', async e => {
    const b = e.target.closest('.copy');
    if (!b) return;
    const m = words();
    try {
      await navigator.clipboard.writeText(b.parentElement.querySelector('code').innerText);
      b.textContent = m.copie; b.classList.add('ok');
    } catch { b.textContent = m.echec; }
    setTimeout(() => { b.textContent = words().copy; b.classList.remove('ok'); }, 1600);
  });

  /* --- theme: LIGHT by default, the toggle is remembered --- */
  const KEY = __CLE__ + '-theme';
  const stored = localStorage.getItem(KEY);
  if (stored) document.documentElement.dataset.theme = stored;
  function updateTheme() {
    const dark = (document.documentElement.dataset.theme || 'light') === 'dark';
    const m = words();
    document.querySelectorAll('[data-theme-toggle]').forEach(b => {
      b.textContent = dark ? '☀' : '☾';
      b.title = dark ? m.vers_clair : m.vers_sombre;
      b.setAttribute('aria-label', b.title);
    });
    /* Segmented group of the sidebar: state + labels (which follow the language). */
    document.querySelectorAll('.themes button').forEach(b => {
      const active = b.dataset.themeSet === (dark ? 'dark' : 'light');
      b.setAttribute('aria-pressed', String(active));
      b.textContent = (b.dataset.themeSet === 'dark' ? '☾ ' : '☀ ')
                    + (b.dataset.themeSet === 'dark' ? m.theme_sombre : m.theme_clair);
    });
    document.querySelectorAll('.themes').forEach(g => g.setAttribute('aria-label', m.theme_aria));
  }
  document.querySelectorAll('.themes button').forEach(b => b.addEventListener('click', () => {
    document.documentElement.dataset.theme = b.dataset.themeSet;
    localStorage.setItem(KEY, b.dataset.themeSet);
    updateTheme();
  }));
  document.querySelectorAll('[data-theme-toggle]').forEach(b => b.addEventListener('click', () => {
    const next_ = (document.documentElement.dataset.theme || 'light') === 'dark' ? 'light' : 'dark';
    document.documentElement.dataset.theme = next_;
    localStorage.setItem(KEY, next_);
    updateTheme();
  }));

  /* --- menu mobile --- */
  const toggle = ouvrir => {
    menu.classList.toggle('open', ouvrir);
    overlay.classList.toggle('open', ouvrir);
  };
  document.querySelector('[data-menu-toggle]').addEventListener('click',
    () => toggle(!menu.classList.contains('open')));
  overlay.addEventListener('click', () => toggle(false));
  links.forEach(a => a.addEventListener('click', () => toggle(false)));

  addEventListener('hashchange', router);
  updateLang(lang);
  router();
})();
"""


# ===========================================================================
#  Assemblage
# ===========================================================================

def lang_selector(words: dict[str, str]) -> str:
    """EN/FR buttons. Rendered twice (sidebar and mobile top bar)."""
    buttons = "".join(
        f'<button type="button" data-lang="{l}" aria-pressed="false">{l.upper()}</button>'
        for l in LANGS
    )
    return (f'<div class="langs" role="group" '
            f'aria-label="{html.escape(words["langue_aria"], quote=True)}">{buttons}</div>')


def theme_selector(words: dict[str, str]) -> str:
    """An EXPLICIT light/dark selector, placed in the sidebar.

    There were already two `data-theme-toggle` switches: one in the mobile top bar, one
    floating at the bottom right. But the mobile top bar is `display:none` on a desktop, so
    the only visible control on desktop was an unlabelled ☀ pill, in a corner, on top
    of the content — invisible in practice. So we add a segmented "Light / Dark" group
    modelled on the language selector, in the same place and with the same shape: that is
    where the eye looks for it. The two original switches stay in place and share state.
    """
    buttons = "".join(
        f'<button type="button" data-theme-set="{value}" aria-pressed="false">'
        f'{icon} {html.escape(words[key])}</button>'
        for value, icon, key in (("light", "☀", "theme_clair"), ("dark", "☾", "theme_sombre"))
    )
    return (f'<div class="themes" role="group" '
            f'aria-label="{html.escape(words["theme_aria"], quote=True)}">{buttons}</div>')


# The official GitHub mark (viewBox 16x16, single path). Inline because the page must stay
# self-contained: no network request at load time.
SVG_GITHUB = (
    '<svg viewBox="0 0 16 16" aria-hidden="true" focusable="false"><path d="M8 0C3.58 0 '
    '0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01'
    '.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 '
    '1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87'
    '.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36'
    '.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 '
    '3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55'
    '.38A8.012 8.012 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg>'
)


def repo_link(words: dict[str, str]) -> str:
    """Badge « GitHub » de la ligne de brand, en haut du menu de gauche.

    The visible label stays "GitHub" in both languages (it is a proper noun); only the
    accessible label is translated, and the JS updates it when the language changes.
    au changement de lang (cf. updateLang).
    """
    intitule = html.escape(words["repo"], quote=True)
    return (f'<a class="repo" href="{REPO_URL}" target="_blank" rel="noopener noreferrer"'
            f' data-repo title="{intitule}" aria-label="{intitule}">{SVG_GITHUB}'
            f'<span>GitHub</span></a>')


def rendre(docs: list[dict]) -> list[dict]:
    """Renders every document in every language (one entry per HTML page)."""
    md = make_converter()
    rendered_pages: list[dict] = []
    for doc in docs:
        for lang in LANGS:
            path = doc["paths"][lang]
            page = {
                "path": path,
                "emoji": doc["emoji"],
                "text": read_page(path),
                "id": f"{lang}/{doc['id']}",
            }
            r = convert(md, page)
            rendered_pages.append({
                **r,
                "id": page["id"],
                "doc": doc["id"],
                "lang": lang,
                "path": path,
                "group": doc["group"][lang],
                "tracked": doc["tracked"],
                # a document with no mirror shows up in English in the French menu;
                # the NO_MIRROR ones own that and carry no badge
                "translated": (doc["paths"]["en"] != doc["paths"]["fr"]
                            or lang == "en" or doc["path"] in NO_MIRROR),
            })
    return rendered_pages


def build_page(rendered_pages: list[dict], version: str, warnings: list[str]) -> str:
    # index path → route, per language: the links of a French page target the French
    # mirrors; the English path is the fallback (an untranslated page).
    index: dict[str, dict[str, str]] = {l: {} for l in LANGS}
    anchors: dict[str, set[str]] = {}
    for r in rendered_pages:
        index[r["lang"]][r["path"]] = r["id"]
        anchors[r["id"]] = set(RE_HEADING_ID.findall(r["body"]))
    for r in rendered_pages:
        index[r["lang"]].setdefault(
            next(x["path"] for x in rendered_pages
                 if x["doc"] == r["doc"] and x["lang"] == "en"), r["id"])

    articles: list[str] = []
    menus: dict[str, dict[str, list[str]]] = {l: {} for l in LANGS}

    for r in rendered_pages:
        words = LABELS[r["lang"]]
        body = inline_images(resolve_links(r, index, anchors, warnings),
                               r["path"], warnings)
        badges = ""
        if not r["tracked"]:
            badges += (f'<span class="badge" title="{html.escape(words["badge_title"], quote=True)}">'
                       f'{html.escape(words["badge"])}</span>')
        if not r["translated"]:
            badges += (f'<span class="badge badge-lang" '
                       f'title="{html.escape(words["badge_langue_titre"], quote=True)}">'
                       f'{html.escape(words["badge_lang"])}</span>')

        # the first callout is promoted to a standfirst under the title (the neutralised H1
        # leaves blanks at the top: hence the lstrip before matching)
        chapeau = ""
        body = body.lstrip()
        m = re.match(r'<blockquote class="callout[^"]*">(.*?)</blockquote>\s*', body, re.DOTALL)
        if m:
            chapeau, body = m.group(1), body[m.end():]

        articles.append(
            f'<article class="page" id="{r["id"]}" data-doc="{r["doc"]}" '
            f'data-lang="{r["lang"]}" '
            f'data-title="{html.escape(r["title_text"], quote=True)}">'
            f'<div class="breadcrumb"><span>{html.escape(r["path"])}</span>{badges}</div>'
            f'<h1><span class="emo">{r["emoji"]}</span>{r["title_html"]}</h1>'
            f'{f"""<div class="subtitle">{chapeau}</div>""" if chapeau else ""}'
            f'{body}'
            f'<div class="footer">'
            f'<span>{html.escape(words["source"])} <code>{html.escape(r["path"])}</code></span>'
            f'<span>{len(r["toc"])} {html.escape(words["sections"])}</span></div>'
            "</article>"
        )

        search = html.escape(" ".join(
            [r["title_text"], r["path"], *(s["title"] for s in r["toc"])]).lower(),
            quote=True)
        menus[r["lang"]].setdefault(r["group"], []).append(
            f'<a href="#{r["id"]}" data-page="{r["id"]}" data-search="{search}">'
            f'<span class="emo">{r["emoji"]}</span>'
            f'<span class="txt">{html.escape(r["title_text"])}{badges}'
            f'<span class="path">{html.escape(r["path"])}</span></span></a>'
        )

    arbres = []
    for lang in LANGS:
        ordre = [g[0][lang] for g in GROUPS] + [OTHERS[lang]]
        nav = "".join(
            f'<nav class="group"><h2>{html.escape(g)}</h2>{"".join(menus[lang][g])}</nav>'
            for g in ordre if g in menus[lang]
        )
        arbres.append(f'<div class="tree" data-lang="{lang}" hidden>{nav}</div>')

    words = LABELS[DEFAULT_LANG]
    js = (JS.replace("__LANGUES__", json.dumps(list(LANGS)))
            .replace("__LIBELLES__", json.dumps(LABELS, ensure_ascii=False))
            .replace("__DEFAUT__", json.dumps(DEFAULT_LANG))
            .replace("__CLE__", json.dumps(STORAGE_KEY))
            .replace("__NOM__", json.dumps(PROJECT_NAME)))

    return f"""<!doctype html>
<html lang="{DEFAULT_LANG}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark light">
<meta name="generator" content="docs/build.py">
<meta name="description" content="{html.escape(words['subtitle'], quote=True)}">
<title>{PROJECT_NAME} · Documentation</title>
<style>
{CSS}
{pygments_css()}
</style>
</head>
<body>
<div class="overlay"></div>
<header class="topbar">
  <button class="icon-button" data-menu-toggle aria-label="{html.escape(words['menu'], quote=True)}">☰</button>
  <strong>{PROJECT_NAME}</strong>
  {lang_selector(words)}
  <button class="icon-button" data-theme-toggle>☾</button>
</header>
<div class="wrapper">
  <aside class="menu">
    <div class="brand">
      <div class="brand-title">
        <span class="logo">{LOGO}</span>
        <span>{PROJECT_NAME}<small>{html.escape(version)}</small></span>
      </div>
      {repo_link(words)}
    </div>
    {lang_selector(words)}
    {theme_selector(words)}
    <div class="search">
      <input type="search" placeholder="{html.escape(words['search'], quote=True)}"
             aria-label="{html.escape(words['search_aria'], quote=True)}">
    </div>
    {"".join(arbres)}
  </aside>
  <main class="content">{"".join(articles)}</main>
  <aside class="toc" aria-label="{html.escape(words['toc'], quote=True)}"></aside>
</div>
<button class="icon-button theme-floating" data-theme-toggle>☾</button>
<script>{js}</script>
</body>
</html>
"""


def main() -> int:
    ap = argparse.ArgumentParser(description="Generates the lab's HTML documentation.")
    ap.add_argument("--out", default=str(ROOT / "docs" / "index.html"),
                    help="output file (default: docs/index.html)")
    ap.add_argument("--strict", action="store_true",
                    help="fail if an internal link or anchor does not resolve")
    args = ap.parse_args()

    docs = discover()
    if not docs:
        print("No markdown file found.", file=sys.stderr)
        return 1
    for doc in docs:  # identifiant de route, stable et lisible
        doc["id"] = re.sub(r"[^a-z0-9]+", "-",
                           doc["path"].lower().removesuffix(".md")).strip("-")

    warnings: list[str] = []
    rendered_pages = rendre(docs)
    sortie = Path(args.out)
    sortie.parent.mkdir(parents=True, exist_ok=True)
    sortie.write_text(
        build_page(rendered_pages, git("log", "-1", "--format=%h · %cs") or "local", warnings),
        encoding="utf-8")

    affiche = sortie.relative_to(ROOT) if sortie.is_relative_to(ROOT) else sortie
    print(f"✅ {affiche} — {len(docs)} documents × {len(LANGS)} langs "
          f"= {len(rendered_pages)} pages, {sortie.stat().st_size // 1024} Ko")
    for doc in docs:
        state = "" if doc["tracked"] else "  (untracked)"
        mirror = doc["paths"]["fr"]
        if mirror == doc["path"]:
            # tell an oversight (to be fixed) from a deliberate choice (NO_MIRROR)
            state += ("  (EN only, deliberate)" if doc["path"] in NO_MIRROR
                     else "  (⚠️ pas de mirror FR)")
            mirror = "—"
        print(f"   {doc['emoji']} {doc['path']:44s} ↔ {mirror}{state}")

    if warnings:
        print(f"\n⚠️ {len(warnings)} unresolved internal link(s):", file=sys.stderr)
        for a in sorted(set(warnings)):
            print(f"   {a}", file=sys.stderr)
        if args.strict:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

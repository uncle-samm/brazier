"""Mechanical checks for Brazier's Markdown docs.

Run it through `scripts/check_docs.sh`, which also compiles the samples.

Two checks:

- `links`: every relative Markdown link, and every backticked path ending in
  `.md`, names a file that exists; a `#anchor` names a heading in that file.
- `samples`: every ```gleam block in a compiled doc is written into a scratch
  Gleam project (`build/docs_check`) that depends on Brazier by path. The
  shell script then runs `gleam build --warnings-as-errors` on it.

Sample markers, an HTML comment on the line directly above the fence (GitHub
does not render them):

- no marker: the block is a complete module and must compile on its own;
- `<!-- docs-check: module NAME -->`: a complete module compiled as module
  NAME, so another block can `import NAME`;
- `<!-- docs-check: wrap` ... `-->`: the comment's lines, with the block put
  in place of the `{{block}}` line, form a complete module (the imports and
  the function around a snippet stay out of the rendered page);
- `<!-- docs-check: fragment REASON -->`: not compiled; REASON is mandatory
  and says why the block cannot be a module (pseudocode, a shell transcript,
  an excerpt of a larger module shown elsewhere in full).

Every failure is printed with its doc file and line, and the exit status is 1.
Nothing is skipped silently: the docs excluded from compilation are listed in
`NOT_COMPILED` with the reason, and printed on every run.
"""

from __future__ import annotations

import re
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRATCH = ROOT / "build" / "docs_check"
SAMPLE_PACKAGE = "docs_check"

# Docs whose ```gleam blocks are not compiled, and why. Links are still
# checked in all of them except the historical progress logs.
NOT_COMPILED = {
    "docs/PROGRESS.md": "historical progress log; its notes quote old APIs on purpose",
    "docs/archive/PROGRESS.md": "historical progress log (Milestones 1-116), copied verbatim",
    "docs/design/API_REDESIGN.md": "historical design record; its samples show the proposal as decided on 2026-11-02",
    "docs/design/CLUSTER_PRESENCE_TELEMETRY.md": "historical design record; its samples show the proposal as decided",
}

# Docs whose links are not checked, and why.
LINKS_NOT_CHECKED = {
    "docs/PROGRESS.md": "historical progress log; it names files that were later deleted on purpose",
    "docs/archive/PROGRESS.md": "historical progress log, copied verbatim",
}

FENCE_OPEN = re.compile(r"^```gleam\s*$")
FENCE_ANY = re.compile(r"^```")
INDENTED_GLEAM = re.compile(r"^\s+```gleam")
MARKER = re.compile(r"^<!--\s*docs-check:\s*(\w+)\s*(.*?)\s*(-->)?\s*$")
MODULE_NAME = re.compile(r"^[a-z][a-z0-9_]*(/[a-z][a-z0-9_]*)*$")
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
IMAGE = re.compile(r"!\[[^\]]*\]\(([^)\s]+)\)")
BACKTICK_MD = re.compile(r"`([A-Za-z0-9_./-]+\.md)(#[A-Za-z0-9_-]+)?`")


class CheckError(Exception):
    pass


@dataclass
class Block:
    doc: str
    line: int  # 1-based line of the opening fence
    code: str
    kind: str  # "module", "named", "wrap", "fragment"
    name: str | None
    prefix: str
    suffix: str


def doc_files() -> list[str]:
    files = ["README.md", "CHANGELOG.md", "CLAUDE.md", "AGENTS.md"]
    for path in sorted((ROOT / "docs").rglob("*.md")):
        files.append(path.relative_to(ROOT).as_posix())
    missing = [f for f in files if not (ROOT / f).is_file()]
    if missing:
        raise CheckError("expected docs are missing: " + ", ".join(missing))
    for listed in list(NOT_COMPILED) + list(LINKS_NOT_CHECKED):
        if listed not in files:
            raise CheckError(f"scripts/docs_check.py lists {listed}, which does not exist")
    return files


# ---------------------------------------------------------------- samples


def parse_blocks(doc: str) -> list[Block]:
    lines = (ROOT / doc).read_text(encoding="utf-8").split("\n")
    blocks: list[Block] = []
    errors: list[str] = []
    i = 0
    in_other_fence = False
    while i < len(lines):
        line = lines[i]
        if in_other_fence:
            if FENCE_ANY.match(line):
                in_other_fence = False
            i += 1
            continue
        if FENCE_OPEN.match(line):
            start = i
            j = i + 1
            while j < len(lines) and not FENCE_ANY.match(lines[j]):
                j += 1
            if j == len(lines):
                errors.append(f"{doc}:{start + 1}: ```gleam block is never closed")
                break
            code = "\n".join(lines[i + 1 : j]) + "\n"
            try:
                blocks.append(classify(doc, lines, start, code))
            except CheckError as err:
                errors.append(str(err))
            i = j + 1
            continue
        if line.lower().startswith("```gleam"):
            errors.append(f"{doc}:{i + 1}: write a Gleam fence as exactly ```gleam so the checker reads it")
        if INDENTED_GLEAM.match(line):
            errors.append(f"{doc}:{i + 1}: indented ```gleam fence; the checker reads only fences in column 0")
        if FENCE_ANY.match(line):
            in_other_fence = True
        i += 1
    if errors:
        raise CheckError("\n".join(errors))
    return blocks


def classify(doc: str, lines: list[str], fence: int, code: str) -> Block:
    """Read the marker comment that ends on the line above `fence`."""
    where = f"{doc}:{fence + 1}"
    above = fence - 1
    if above < 0 or not lines[above].rstrip().endswith("-->"):
        if above >= 0 and "docs-check" in lines[above]:
            raise CheckError(f"{where}: malformed docs-check marker above the block")
        return Block(doc, fence + 1, code, "module", None, "", "")
    # Find where the comment starts (a wrap marker spans several lines).
    start = above
    while start >= 0 and not lines[start].lstrip().startswith("<!--"):
        start -= 1
    if start < 0:
        raise CheckError(f"{where}: comment above the block has no opening <!--")
    head = MARKER.match(lines[start].strip())
    if head is None:
        if "docs-check" in "\n".join(lines[start : above + 1]):
            raise CheckError(f"{where}: malformed docs-check marker above the block")
        return Block(doc, fence + 1, code, "module", None, "", "")
    kind, arg = head.group(1), head.group(2)
    single_line = start == above
    if kind == "fragment":
        if not single_line:
            raise CheckError(f"{where}: a fragment marker must fit on one line")
        if not arg:
            raise CheckError(f"{where}: a fragment marker must give a reason")
        return Block(doc, fence + 1, code, "fragment", None, "", "")
    if kind == "module":
        if not single_line or not MODULE_NAME.match(arg):
            raise CheckError(f"{where}: expected <!-- docs-check: module NAME --> with a Gleam module name")
        return Block(doc, fence + 1, code, "named", arg, "", "")
    if kind == "wrap":
        if single_line or arg:
            raise CheckError(f"{where}: a wrap marker puts its module lines below `<!-- docs-check: wrap`")
        body = lines[start + 1 : above]
        last = lines[above].strip()
        if last != "-->":
            raise CheckError(f"{where}: end a wrap marker with `-->` on its own line")
        holes = [k for k, text in enumerate(body) if text.strip() == "{{block}}"]
        if len(holes) != 1:
            raise CheckError(f"{where}: a wrap marker needs exactly one `{{{{block}}}}` line")
        hole = holes[0]
        indent = body[hole][: len(body[hole]) - len(body[hole].lstrip())]
        indented = "\n".join((indent + text) if text else text for text in code.rstrip("\n").split("\n"))
        prefix = "\n".join(body[:hole]) + "\n"
        suffix = "\n".join(body[hole + 1 :]) + "\n"
        return Block(doc, fence + 1, indented + "\n", "wrap", None, prefix, suffix)
    raise CheckError(f"{where}: unknown docs-check marker `{kind}` (use module, wrap or fragment)")


def module_path(block: Block) -> str:
    if block.name is not None:
        return block.name
    slug = re.sub(r"[^a-z0-9]+", "_", block.doc.lower().removesuffix(".md")).strip("_")
    return f"{SAMPLE_PACKAGE}/{slug}/l{block.line}"


def write_samples(only: list[str]) -> int:
    """Write the samples of every compiled doc, or of `only` when given."""
    sources: dict[str, Block] = {}
    errors: list[str] = []
    fragments = 0
    docs = doc_files()
    unknown = [doc for doc in only if doc not in docs]
    if unknown:
        raise CheckError("not a checked doc: " + ", ".join(unknown))
    for doc in docs:
        if only and doc not in only:
            continue
        if doc in NOT_COMPILED:
            print(f"docs-check: samples not compiled in {doc}: {NOT_COMPILED[doc]}")
            continue
        try:
            blocks = parse_blocks(doc)
        except CheckError as err:
            errors.append(str(err))
            continue
        for block in blocks:
            if block.kind == "fragment":
                fragments += 1
                continue
            path = module_path(block)
            if path in sources:
                other = sources[path]
                errors.append(
                    f"{block.doc}:{block.line}: module `{path}` is also defined at {other.doc}:{other.line}"
                )
                continue
            sources[path] = block
    if errors:
        raise CheckError("\n".join(errors))

    src = SCRATCH / "src"
    if src.exists():
        shutil.rmtree(src)
    src.mkdir(parents=True)
    write_project_files()
    index = []
    for path, block in sorted(sources.items()):
        target = src / (path + ".gleam")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(block.prefix + block.code + block.suffix, encoding="utf-8")
        index.append(f"src/{path}.gleam\t{block.doc}:{block.line}\t{block.kind}")
    (SCRATCH / "index.tsv").write_text("\n".join(index) + "\n", encoding="utf-8")
    print(f"docs-check: wrote {len(sources)} sample module(s) to {SCRATCH.relative_to(ROOT)}; {fragments} fragment(s) not compiled")
    if not sources:
        raise CheckError("no compiled samples found; the extractor is broken")
    return len(sources)


def write_project_files() -> None:
    """The scratch project depends on Brazier by path, with Brazier's own
    dependency constraints, so samples may import what Brazier's users get."""
    brazier_toml = (ROOT / "gleam.toml").read_text(encoding="utf-8")
    deps = section(brazier_toml, "dependencies")
    if not deps:
        raise CheckError("gleam.toml has no [dependencies] section")
    toml = (
        f'name = "{SAMPLE_PACKAGE}"\n'
        'version = "0.0.0"\n'
        'target = "erlang"\n\n'
        "[dependencies]\n"
        'brazier = { path = "../.." }\n' + "\n".join(deps) + "\n"
    )
    (SCRATCH / "gleam.toml").write_text(toml, encoding="utf-8")
    drop_stale_lock()


def drop_stale_lock() -> None:
    """The scratch project's manifest.toml locks Brazier, a path dependency,
    at the version it had when the manifest was written. After a version bump
    Gleam refuses that lock ("locked to X, which is incompatible"), so the
    manifest is removed and Gleam resolves again. A manifest with no Brazier
    entry, or more than one, is not one this script wrote: it fails."""
    manifest = SCRATCH / "manifest.toml"
    if not manifest.exists():
        return
    locked = re.findall(
        r'^  \{ name = "brazier", version = "([^"]+)",',
        manifest.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if len(locked) != 1:
        raise CheckError(f"{manifest.relative_to(ROOT)} has {len(locked)} brazier entries, expected 1")
    versions = re.findall(r'^version = "([^"]+)"$', (ROOT / "gleam.toml").read_text(encoding="utf-8"), re.MULTILINE)
    if len(versions) != 1:
        raise CheckError(f"gleam.toml has {len(versions)} top-level version lines, expected 1")
    if locked[0] != versions[0]:
        print(f"docs-check: {manifest.relative_to(ROOT)} locks brazier {locked[0]}, gleam.toml is {versions[0]}; removing it so Gleam resolves again")
        manifest.unlink()


def section(toml: str, name: str) -> list[str]:
    out: list[str] = []
    inside = False
    for line in toml.split("\n"):
        stripped = line.strip()
        if stripped.startswith("["):
            inside = stripped == f"[{name}]"
            continue
        if inside and stripped and not stripped.startswith("#"):
            out.append(stripped)
    return out


# ---------------------------------------------------------------- links


def slugify(heading: str) -> str:
    """GitHub's heading anchor: lowercase, drop punctuation, spaces to dashes."""
    text = re.sub(r"`", "", heading.strip().lower())
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def anchors(path: Path) -> set[str]:
    found: set[str] = set()
    counts: dict[str, int] = {}
    in_fence = False
    for line in path.read_text(encoding="utf-8").split("\n"):
        if FENCE_ANY.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        match = re.match(r"^#{1,6}\s+(.*?)\s*#*\s*$", line)
        if match:
            slug = slugify(match.group(1))
            n = counts.get(slug, 0)
            counts[slug] = n + 1
            found.add(slug if n == 0 else f"{slug}-{n}")
    return found


def check_links() -> int:
    errors: list[str] = []
    checked = 0
    for doc in doc_files():
        if doc in LINKS_NOT_CHECKED:
            print(f"docs-check: links not checked in {doc}: {LINKS_NOT_CHECKED[doc]}")
            continue
        path = ROOT / doc
        in_fence = False
        for number, line in enumerate(path.read_text(encoding="utf-8").split("\n"), start=1):
            if FENCE_ANY.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            targets = [(m.group(1), False) for m in LINK.finditer(line)]
            targets += [(m.group(1), False) for m in IMAGE.finditer(line)]
            targets += [(m.group(1) + (m.group(2) or ""), True) for m in BACKTICK_MD.finditer(line)]
            for target, backticked in targets:
                if re.match(r"^[a-z][a-z0-9+.-]*:", target):
                    continue  # http:, https:, mailto: and other schemes
                checked += 1
                problem = check_target(path, target, backticked)
                if problem:
                    errors.append(f"{doc}:{number}: {problem}")
    if errors:
        raise CheckError("\n".join(errors))
    print(f"docs-check: {checked} relative link(s) resolve")
    return checked


def check_target(doc: Path, target: str, backticked: bool) -> str | None:
    file_part, _, anchor = target.partition("#")
    if file_part == "":
        resolved = doc
    else:
        candidates = [doc.parent / file_part]
        if backticked:
            # Prose names repository paths from the root (`docs/SECURITY.md`)
            # and the docs by their bare name (`SECURITY.md`).
            candidates.append(ROOT / file_part)
            candidates.append(ROOT / "docs" / file_part)
        existing = [c for c in candidates if c.exists()]
        if not existing:
            return f"`{target}` names a file that does not exist"
        resolved = existing[0]
    if anchor:
        if resolved.is_dir() or resolved.suffix != ".md":
            return f"`{target}` has an anchor on a non-Markdown target"
        if anchor not in anchors(resolved):
            return f"`{target}`: no heading with anchor #{anchor} in {resolved.relative_to(ROOT)}"
    return None


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] not in ("links", "samples") or (argv[1] == "links" and len(argv) > 2):
        print("usage: docs_check.py links | samples [DOC...]", file=sys.stderr)
        return 2
    try:
        if argv[1] == "links":
            check_links()
        else:
            write_samples(argv[2:])
    except CheckError as err:
        print("docs-check: FAILED\n" + str(err), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

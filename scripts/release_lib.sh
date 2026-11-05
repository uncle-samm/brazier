# Shared checks for scripts/push.sh, scripts/tag.sh and scripts/publish.sh.
# Source it from bash running with `set -euo pipefail`, from the repository
# root. Every check either succeeds or exits non-zero with a message.

release_step() {
  echo "release: $*"
}

release_refuse() {
  echo "release: REFUSED: $*" >&2
  exit 1
}

release_require_tools() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      release_refuse "$tool is required but not on PATH"
    fi
  done
}

# What is pushed, tagged or published must be exactly a commit.
release_require_clean_tree() {
  local dirty
  dirty=$(git status --porcelain --untracked-files=normal)
  if [ -n "$dirty" ]; then
    echo "$dirty" >&2
    release_refuse "the working tree is not clean; commit or remove these changes first"
  fi
}

release_require_main() {
  local branch
  branch=$(git branch --show-current)
  if [ "$branch" != "main" ]; then
    release_refuse "not on main (on '${branch:-detached HEAD}'); switch to main first"
  fi
}

# Prints the single top-level `name = "..."` value of gleam.toml.
release_name() {
  local name
  if [ ! -f gleam.toml ]; then release_refuse "gleam.toml is missing"; fi
  # sed exits non-zero only on an I/O error, which set -e turns into a
  # failure; no match prints nothing, which the case below refuses.
  name=$(sed -n -E 's/^name = "([a-z][a-z0-9_]*)"$/\1/p' gleam.toml)
  case "$name" in
    '' | *$'\n'*) release_refuse "gleam.toml must have exactly one top-level name = \"...\" line" ;;
  esac
  printf '%s\n' "$name"
}

# Prints the single top-level `version = "X.Y.Z"` value of gleam.toml.
release_version() {
  local version
  if [ ! -f gleam.toml ]; then release_refuse "gleam.toml is missing"; fi
  version=$(sed -n -E 's/^version = "([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' gleam.toml)
  case "$version" in
    '' | *$'\n'*) release_refuse "gleam.toml must have exactly one top-level version = \"X.Y.Z\" line" ;;
  esac
  printf '%s\n' "$version"
}

# Refuses unless the Hex tarball TARBALL (an outer tar holding
# contents.tar.gz) contains each FILE, a path relative to the package root.
release_require_tarball_file() {
  local tarball="$1"
  shift
  if [ ! -f "$tarball" ]; then release_refuse "$tarball was not built"; fi
  if ! python3 - "$tarball" "$@" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1]) as outer:
    member = outer.extractfile("contents.tar.gz")
    if member is None:
        sys.exit(sys.argv[1] + " has no contents.tar.gz")
    with tarfile.open(fileobj=io.BytesIO(member.read()), mode="r:gz") as inner:
        names = set(inner.getnames())
missing = [path for path in sys.argv[2:] if path not in names]
if missing:
    sys.exit(sys.argv[1] + " is missing " + ", ".join(missing))
PY
  then
    release_refuse "the Hex tarball does not contain what the package needs"
  fi
}

# Refuses unless CHANGELOG.md has a `## [VERSION]` heading (optionally
# followed by ` - YYYY-MM-DD`).
release_require_changelog_heading() {
  local version="$1" version_re
  if [ ! -f CHANGELOG.md ]; then release_refuse "CHANGELOG.md is missing"; fi
  version_re=$(printf '%s' "$version" | sed 's/\./\\./g')
  if ! grep -Eq "^## \[$version_re\]( - [0-9]{4}-[0-9]{2}-[0-9]{2})?$" CHANGELOG.md; then
    release_refuse "CHANGELOG.md has no '## [$version]' heading for the gleam.toml version; move the [Unreleased] entries under one first"
  fi
}

# Refuses unless Hex serves the release NAME VERSION. `gleam publish` exits 0
# when it does not publish (a prompt answered with anything else prints "Not
# publishing."), so its exit status does not show that the release is on Hex.
# A 404 is retried for a minute, the time a new release can take to appear in
# the API; any other answer, or no answer, refuses at once.
release_require_on_hex() {
  local name="$1" version="$2"
  if ! python3 -I - "$name" "$version" <<'PY'
import sys
import time
import urllib.error
import urllib.request

name, version = sys.argv[1], sys.argv[2]
url = "https://hex.pm/api/packages/%s/releases/%s" % (name, version)
request = urllib.request.Request(
    url, headers={"User-Agent": "brazier-release", "Accept": "application/json"}
)
attempts = 10
for attempt in range(1, attempts + 1):
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            status = response.status
    except urllib.error.HTTPError as error:
        status = error.code
    except urllib.error.URLError as error:
        sys.exit("could not reach %s: %s" % (url, error.reason))
    if status == 200:
        sys.exit(0)
    if status != 404:
        sys.exit("%s answered HTTP %d" % (url, status))
    print("release: %s answered 404 (attempt %d of %d)" % (url, attempt, attempts))
    if attempt < attempts:
        time.sleep(6)
sys.exit("%s still answers 404" % url)
PY
  then
    release_refuse "Hex does not serve $name $version, so it was not published"
  fi
}

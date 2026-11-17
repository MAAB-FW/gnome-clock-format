#!/usr/bin/env bash
set -Eeuo pipefail

# Custom GNOME top-bar clock format:
#   %a, %-d %b
#   %-I:%M:%S %p

APP="gnome-clock-format"
STATE="$HOME/.local/share/$APP"

log()  { printf '\n[%s] %s\n' "$APP" "$*"; }
die()  { printf '\n[%s] ERROR: %s\n' "$APP" "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

usage() {
  cat <<USAGE
Usage:
  bash $0 install    Build and install a clock-format RPM for this Fedora system.
  bash $0 uninstall  Restore the exact GNOME RPMs saved before installation.
USAGE
}

[[ $# -eq 1 ]] || { usage; exit 2; }
ACTION=$1

case "$ACTION" in
  install)
    [[ -f /etc/fedora-release ]] || die "Fedora not detected. This script supports Fedora only."
    [[ ! -e "$STATE" ]] || die "State already exists at $STATE. Run uninstall first, or inspect that directory."

    need rpm
    need dnf
    need sudo
    need python3
    need tar
    need diff
    need find

    FEDORA=$(rpm -E %fedora)
    [[ "$FEDORA" =~ ^[0-9]+$ ]] || die "Could not detect Fedora release."
    GNOME_SHELL=$(gnome-shell --version 2>/dev/null || true)
    [[ -n "$GNOME_SHELL" ]] || die "GNOME Shell not detected."

    # The GNOME 4 package is preferred where present; older Fedora builds may
    # still expose the library through gnome-desktop3.
    if rpm -q gnome-desktop4 >/dev/null 2>&1; then
      PRIMARY=gnome-desktop4
    elif rpm -q gnome-desktop3 >/dev/null 2>&1; then
      PRIMARY=gnome-desktop3
    else
      die "Neither gnome-desktop4 nor gnome-desktop3 is installed."
    fi

    # Keep all installed library packages from this source package so uninstall
    # can restore their exact original RPM files as one transaction.
    PACKAGES=()
    for p in gnome-desktop3 gnome-desktop4; do
      rpm -q "$p" >/dev/null 2>&1 && PACKAGES+=("$p")
    done
    ((${#PACKAGES[@]} > 0)) || die "No supported GNOME desktop packages found."

    PRIMARY_EVR=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$PRIMARY")
    PRIMARY_SRPM=$(rpm -q --qf '%{SOURCERPM}' "$PRIMARY")
    [[ "$PRIMARY_SRPM" != "(none)" && "$PRIMARY_SRPM" == *.src.rpm ]] || die "Cannot identify the installed package's source RPM."

    WORK=$(mktemp -d "${TMPDIR:-/tmp}/$APP.XXXXXXXX")
    cleanup() {
      rc=$?
      rm -rf "$WORK"
      exit "$rc"
    }
    trap cleanup EXIT

    mkdir -p "$WORK/srpm" "$WORK/original" \
      "$WORK/topdir/BUILD" "$WORK/topdir/BUILDROOT" \
      "$WORK/topdir/RPMS" "$WORK/topdir/SOURCES" \
      "$WORK/topdir/SPECS" "$WORK/topdir/SRPMS"

    log "Fedora $FEDORA; $GNOME_SHELL; primary package $PRIMARY-$PRIMARY_EVR"
    log "Installing RPM build/download tooling."
    sudo dnf install -y dnf-plugins-core rpm-build
    dnf download --help >/dev/null 2>&1 || die "DNF download plugin unavailable. Install the Fedora package providing 'dnf download'."
    dnf builddep --help >/dev/null 2>&1 || die "DNF builddep plugin unavailable. Install the Fedora package providing 'dnf builddep'."

    log "Downloading the exact source RPM: $PRIMARY_SRPM"
    dnf download --source --destdir "$WORK/srpm" "$PRIMARY-$PRIMARY_EVR"
    SRPM="$WORK/srpm/$PRIMARY_SRPM"
    [[ -f "$SRPM" ]] || die "Downloaded source RPM does not match installed source RPM $PRIMARY_SRPM. Refusing a mismatched build."

    log "Downloading exact currently-installed binary RPMs for rollback."
    for p in "${PACKAGES[@]}"; do
      evr=$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$p")
      arch=$(rpm -q --qf '%{ARCH}' "$p")
      expected="$p-$evr.$arch.rpm"
      dnf download --destdir "$WORK/original" "$p-$evr.$arch"
      [[ -f "$WORK/original/$expected" ]] || die "Could not download exact rollback RPM: $expected. No GNOME packages have been changed."
    done

    log "Extracting source RPM."
    rpm -i --nodeps --define "_topdir $WORK/topdir" "$SRPM"
    mapfile -t SPECS < <(find "$WORK/topdir/SPECS" -maxdepth 1 -type f -name '*.spec' -print)
    ((${#SPECS[@]} == 1)) || die "Expected one spec file in source RPM; found ${#SPECS[@]}."
    SPEC=${SPECS[0]}

    # Fail closed if this release no longer uses the expected RPM patch flow.
    grep -Eq '^%autosetup([[:space:]].*)?-p1([[:space:]]|$)' "$SPEC" || \
      die "Spec does not use '%autosetup -p1'. Source layout/patch flow changed; refusing an unsafe build."
    if grep -Eq '^Patch999:' "$SPEC"; then
      die "Spec already defines Patch999; refusing to overwrite an existing patch entry."
    fi

    log "Installing build dependencies from the matching spec."
    sudo dnf builddep --assumeyes "$SPEC"

    log "Preparing source and applying the distribution's existing patches."
    rpmbuild -bp --define "_topdir $WORK/topdir" "$SPEC"
    mapfile -t CLOCK_FILES < <(find "$WORK/topdir/BUILD" -type f -path '*/libgnome-desktop/gnome-wall-clock.c' -print)
    ((${#CLOCK_FILES[@]} == 1)) || die "Expected one libgnome-desktop/gnome-wall-clock.c after %prep; found ${#CLOCK_FILES[@]}. This GNOME source layout is not supported."
    CLOCK_FILE=${CLOCK_FILES[0]}
    SOURCE_ROOT=${CLOCK_FILE%/libgnome-desktop/gnome-wall-clock.c}
    cp -p "$CLOCK_FILE" "$CLOCK_FILE.clock-format-original"

    log "Applying the custom clock format to the prepared source."
    python3 - "$CLOCK_FILE" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
marker = "if (clock_format == G_DESKTOP_CLOCK_FORMAT_24H)"
if text.count(marker) != 1:
    raise SystemExit(f"Expected exactly one '{marker}' block; found {text.count(marker)}")

start = text.index(marker)
open_brace = text.find("{", start)
if open_brace < 0:
    raise SystemExit("Could not find opening brace for clock-format selection")

def matching_brace(source: str, opening: int) -> int:
    depth = 0
    in_string = False
    in_char = False
    escaped = False
    line_comment = False
    block_comment = False
    i = opening
    while i < len(source):
        ch = source[i]
        nxt = source[i + 1] if i + 1 < len(source) else ""
        if line_comment:
            if ch == "\n": line_comment = False
        elif block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 1
        elif in_string or in_char:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif in_string and ch == '"':
                in_string = False
            elif in_char and ch == "'":
                in_char = False
        elif ch == "/" and nxt == "/":
            line_comment = True
            i += 1
        elif ch == "/" and nxt == "*":
            block_comment = True
            i += 1
        elif ch == '"':
            in_string = True
        elif ch == "'":
            in_char = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise SystemExit("Unbalanced braces in clock-format selection")

first_close = matching_brace(text, open_brace)
after_first = first_close + 1
while after_first < len(text) and text[after_first].isspace():
    after_first += 1
if not text.startswith("else", after_first):
    raise SystemExit("Expected an 'else' branch after the 24-hour format branch")
else_open = text.find("{", after_first + 4)
if else_open < 0:
    raise SystemExit("Could not find opening brace for AM/PM format branch")
else_close = matching_brace(text, else_open)

line_start = text.rfind("\n", 0, start) + 1
indent = text[line_start:start]
replacement = 'format_string = "%a, %-d %b\\n%-I:%M:%S %p";'
updated = text[:start] + replacement + text[else_close + 1:]
if updated == text:
    raise SystemExit("Clock source was not changed")
path.write_text(updated)
PY

    PATCH="$WORK/topdir/SOURCES/0001-custom-clock-format.patch"
    if diff -u \
      --label a/libgnome-desktop/gnome-wall-clock.c \
      --label b/libgnome-desktop/gnome-wall-clock.c \
      "$CLOCK_FILE.clock-format-original" "$CLOCK_FILE" > "$PATCH"; then
      die "No source changes detected; refusing to build an unmodified RPM."
    else
      diff_rc=$?
      [[ $diff_rc -eq 1 ]] || die "diff failed with exit code $diff_rc."
    fi
    rm -f "$CLOCK_FILE.clock-format-original"
    [[ -s "$PATCH" ]] || die "Generated patch is empty."

    log "Registering patch and assigning a local RPM release."
    python3 - "$SPEC" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
if any(re.match(r"^Patch999\s*:", line) for line in lines):
    raise SystemExit("Patch999 already exists in spec")
source_indexes = [i for i, line in enumerate(lines) if re.match(r"^Source\d*\s*:", line)]
if not source_indexes:
    raise SystemExit("No Source: entry found in spec")
release_indexes = [i for i, line in enumerate(lines) if re.match(r"^Release\s*:", line)]
if len(release_indexes) != 1:
    raise SystemExit(f"Expected one Release: entry; found {len(release_indexes)}")
lines.insert(source_indexes[-1] + 1, "Patch999: 0001-custom-clock-format.patch")
release_indexes = [i for i, line in enumerate(lines) if re.match(r"^Release\s*:", line)]
lines[release_indexes[0]] = "Release: 9999.customclock%{?dist}"
path.write_text("\n".join(lines) + "\n")
PY

    log "Building RPMs."
    rpmbuild -ba --define "_topdir $WORK/topdir" "$SPEC"

    mapfile -t BUILT_RPMS < <(find "$WORK/topdir/RPMS" -type f -name '*.rpm' -print)
    INSTALL_RPMS=()
    for p in "${PACKAGES[@]}"; do
      match=""
      for f in "${BUILT_RPMS[@]}"; do
        [[ $(rpm -qp --qf '%{NAME}' "$f" 2>/dev/null || true) == "$p" ]] && match=$f
      done
      [[ -n "$match" ]] || die "Build did not produce required package $p. Refusing partial installation."
      INSTALL_RPMS+=("$match")
    done

    log "Saving exact rollback RPMs."
    mkdir -p "$STATE/original"
    cp "$WORK/original"/*.rpm "$STATE/original/"
    {
      printf 'FEDORA=%q\n' "$FEDORA"
      printf 'GNOME_SHELL=%q\n' "$GNOME_SHELL"
      printf 'PRIMARY=%q\n' "$PRIMARY"
      printf 'PRIMARY_EVR=%q\n' "$PRIMARY_EVR"
    } > "$STATE/metadata"

    log "Installing custom RPMs. Review the DNF transaction before confirming."
    sudo dnf install "${INSTALL_RPMS[@]}"

    for p in "${PACKAGES[@]}"; do
      rel=$(rpm -q --qf '%{RELEASE}' "$p")
      [[ "$rel" == 9999.customclock.fc"$FEDORA" ]] || die "Post-install verification failed for $p (release: $rel)."
    done

    log "Installation successful. Log out and log back in to restart GNOME Shell."
    log "Rollback data saved at: $STATE"
    ;;

  uninstall)
    need rpm
    need sudo
    [[ -d "$STATE/original" ]] || die "No saved rollback RPMs found at $STATE/original. Nothing changed."
    mapfile -t ORIGINAL_RPMS < <(find "$STATE/original" -maxdepth 1 -type f -name '*.rpm' -print | sort)
    ((${#ORIGINAL_RPMS[@]} > 0)) || die "Rollback RPM directory is empty. Cannot safely restore packages."

    log "Restoring the exact GNOME RPMs saved before custom installation."
    sudo rpm -Uvh --oldpackage --replacepkgs "${ORIGINAL_RPMS[@]}"

    for f in "${ORIGINAL_RPMS[@]}"; do
      name=$(rpm -qp --qf '%{NAME}' "$f")
      expected=$(rpm -qp --qf '%{VERSION}-%{RELEASE}.%{ARCH}' "$f")
      actual=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' "$name")
      [[ "$actual" == "$expected" ]] || die "Restore verification failed for $name: expected $expected, found $actual. State retained at $STATE."
    done

    rm -rf "$STATE"
    log "Uninstall/restore successful. Original GNOME RPM versions restored."
    log "Build dependencies installed by DNF are left in place; they may be shared by other software."
    log "Log out and log back in to restart GNOME Shell."
    ;;

  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac

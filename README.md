# GNOME Clock Format

Set GNOME’s top-bar clock to this two-line format:

```text
Tue, 17 Nov
1:09:31 PM
```

The script rebuilds Fedora’s installed `gnome-desktop` RPM with a small clock-format patch. It supports Fedora with GNOME Shell and installed `gnome-desktop3` or `gnome-desktop4` packages.

## Install

Run from this directory:

```bash
bash gnome-clock-format.sh install
```

The script downloads the matching Fedora source RPM and exact installed binary RPMs, installs RPM build tools and build dependencies, builds patched RPMs, then asks DNF to install them. Review the DNF transaction before confirming. You may need to enter your sudo password.

Log out and log back in after successful installation to restart GNOME Shell.

## Restore original packages

Run:

```bash
bash gnome-clock-format.sh uninstall
```

This restores the exact GNOME RPM files saved during installation, verifies the restored versions, and removes the saved rollback data. DNF build dependencies remain installed; remove them manually if no longer needed.

## Requirements

- Fedora Linux with GNOME Shell
- Bash
- `rpm`, `dnf`, `sudo`, `python3`, `tar`, `diff`, and `find`
- DNF download and build-dependency plugins
- Internet access to download Fedora source, binary RPMs, and build dependencies

The script installs `dnf-plugins-core` and `rpm-build` through DNF when needed. It stops if the installed Fedora source layout does not match the expected patch flow.

## Safety and recovery

Installation stores rollback RPMs and metadata in:

```text
~/.local/share/gnome-clock-format/
```

The script refuses another install while this state directory exists. Use `uninstall` to restore the saved packages and clear that state. Do not delete the state directory before restoring; it contains the RPMs needed for rollback.

The clock change lives in rebuilt Fedora RPMs. A later Fedora package update may replace it. Re-run `install` after updates if needed.

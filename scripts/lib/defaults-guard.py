#!/usr/bin/env python3
# The test host uses bundle id com.magnusgoedde.whispershortcut.dev, the same
# UserDefaults domain as the daily Dev app. Tests write through
# UserDefaults.standard and cannot read the keychain, so they store offline
# models in the user's real settings. On 2026-11-17 a run switched a live
# meeting's chat to the offline model; this puts only those keys back.

"""Snapshot and restore a narrow set of UserDefaults keys around a test run."""

from __future__ import annotations

import plistlib
import subprocess
import sys

_MISSING = object()


def _is_guarded(key: str) -> bool:
    return (
        key.startswith("selected")
        or key.startswith("offlineMode")
        or key == "cloudModelOfferDeclinedProviders"
    )


def _export_domain(domain: str) -> bytes | None:
    """Raw `defaults export` bytes, or None when the domain does not exist."""
    proc = subprocess.run(
        ["defaults", "export", domain, "-"],
        capture_output=True,
    )
    err = proc.stderr.decode("utf-8", errors="replace")
    if _output_says_missing(err):
        return None
    if proc.returncode != 0:
        detail = " ".join(err.split()) or f"exit {proc.returncode}"
        raise RuntimeError(f"defaults export {domain} failed: {detail}")
    # This macOS exits 0 and prints an empty plist for a domain that does not exist.
    if _domain_missing(domain):
        return None
    return proc.stdout


def _output_says_missing(err: str) -> bool:
    return "does not exist" in err or "not found" in err


def _domain_missing(domain: str) -> bool:
    proc = subprocess.run(["defaults", "read", domain], capture_output=True)
    if proc.returncode == 0:
        return False
    err = proc.stderr.decode("utf-8", errors="replace")
    if _output_says_missing(err):
        return True
    detail = " ".join(err.split()) or f"exit {proc.returncode}"
    raise RuntimeError(f"defaults read {domain} failed: {detail}")


def _import_domain(domain: str, payload: dict) -> None:
    proc = subprocess.run(
        ["defaults", "import", domain, "-"],
        input=plistlib.dumps(payload),
        capture_output=True,
    )
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", errors="replace")
        detail = " ".join(err.split()) or f"exit {proc.returncode}"
        raise RuntimeError(f"defaults import {domain} failed: {detail}")


def _delete_key(domain: str, key: str) -> None:
    proc = subprocess.run(
        ["defaults", "delete", domain, key],
        capture_output=True,
    )
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", errors="replace")
        detail = " ".join(err.split()) or f"exit {proc.returncode}"
        raise RuntimeError(f"defaults delete {domain} {key} failed: {detail}")


def _load_plist(data: bytes, label: str) -> dict:
    loaded = plistlib.loads(data)
    if not isinstance(loaded, dict):
        raise RuntimeError(f"{label} is not a dictionary")
    return loaded


def snapshot(domain: str, path: str) -> None:
    data = _export_domain(domain)
    if data is None:
        data = plistlib.dumps({})
    with open(path, "wb") as handle:
        handle.write(data)


def restore(domain: str, path: str) -> None:
    with open(path, "rb") as handle:
        saved = _load_plist(handle.read(), "snapshot")
    exported = _export_domain(domain)
    current = {} if exported is None else _load_plist(exported, "current defaults")

    merged = dict(current)
    reverted: list[str] = []
    removed: list[str] = []
    left: list[str] = []
    for key in sorted(set(saved) | set(current)):
        before = saved[key] if key in saved else _MISSING
        after = current[key] if key in current else _MISSING
        if before == after:
            continue
        if _is_guarded(str(key)):
            if before is _MISSING:
                merged.pop(key, None)
                removed.append(str(key))
            else:
                merged[key] = before
            reverted.append(str(key))
        else:
            left.append(str(key))

    if reverted:
        # `defaults import` merges. A key the snapshot never had stays unless deleted.
        _import_domain(domain, merged)
        for key in removed:
            _delete_key(domain, key)
        for key in reverted:
            print(f"\u21a9\ufe0f  restored {key}")
    if left:
        print("\u2139\ufe0f  tests also changed (left as is): " + ", ".join(left))


def main(argv: list[str]) -> int:
    try:
        if len(argv) != 4 or argv[1] not in ("snapshot", "restore"):
            raise RuntimeError("usage: defaults-guard.py snapshot|restore <domain> <file>")
        command, domain, path = argv[1], argv[2], argv[3]
        if command == "snapshot":
            snapshot(domain, path)
        else:
            restore(domain, path)
    except Exception as exc:
        detail = " ".join(str(exc).split()) or exc.__class__.__name__
        print(f"defaults-guard: {detail}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

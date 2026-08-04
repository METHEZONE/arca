#!/usr/bin/env python3
"""
Resolve and download ESP-IDF managed components into ./components, so the build
can run with IDF_COMPONENT_MANAGER=0.

Why you would want this:
  - the IDF component manager needs pydantic, whose native extension will not
    load in some sandboxed/hardened environments ("library load disallowed by
    system policy"). Vendoring sidesteps Python entirely at configure time.
  - it pins an exact, inspectable set of third-party sources in the tree instead
    of resolving them on every clean build.

Talks to the public registry with nothing but urllib, json and tarfile - no
third-party packages, so it works wherever plain Python works.

    python3 tools/vendor_components.py                 # read main/idf_component.yml
    python3 tools/vendor_components.py lvgl/lvgl:^9.2.0
"""

import json
import os
import re
import shutil
import sys
import tempfile
import zipfile
import urllib.request

API = "https://components.espressif.com/api/components"
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEST = os.path.join(HERE, "components")

# Provided by IDF itself, never fetched. Vendoring these shadows the in-tree
# version and breaks against the current HAL (the standalone "usb" component on
# the registry does not compile against IDF 5.5).
SKIP = {"idf", "usb"}


def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "arca-core-vendor/1"})
    with urllib.request.urlopen(req, timeout=40) as r:
        return json.loads(r.read().decode())


def parse_version(v):
    core = re.split(r"[-+]", v)[0]
    parts = []
    for p in core.split("."):
        try:
            parts.append(int(p))
        except ValueError:
            parts.append(0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def satisfies(version, spec):
    """Handles the specs that actually appear in IDF manifests."""
    spec = (spec or "*").strip()
    if spec in ("*", "", "^0", "any"):
        return True
    v = parse_version(version)

    for clause in [c.strip() for c in spec.split(",") if c.strip()]:
        if clause.startswith("^"):
            base = parse_version(clause[1:])
            if v < base:
                return False
            # caret: allow changes that do not modify the leftmost non-zero part
            if base[0] > 0:
                if v[0] != base[0]:
                    return False
            elif base[1] > 0:
                if v[0] != 0 or v[1] != base[1]:
                    return False
            else:
                if v[:2] != (0, 0):
                    return False
        elif clause.startswith("~"):
            base = parse_version(clause[1:])
            if v < base or v[:2] != base[:2]:
                return False
        elif clause.startswith(">="):
            if v < parse_version(clause[2:]):
                return False
        elif clause.startswith("<="):
            if v > parse_version(clause[2:]):
                return False
        elif clause.startswith(">"):
            if v <= parse_version(clause[1:]):
                return False
        elif clause.startswith("<"):
            if v >= parse_version(clause[1:]):
                return False
        elif clause.startswith("=="):
            if v != parse_version(clause[2:]):
                return False
        elif "*" in clause:
            # "0.*" / "1.2.*" - match the fixed leading components only.
            fixed = [int(x) for x in clause.split(".") if x != "*" and x.isdigit()]
            if list(v[:len(fixed)]) != fixed:
                return False
        else:
            if v != parse_version(clause):
                return False
    return True


def pick(meta, spec):
    ok = []
    for entry in meta.get("versions", []):
        ver = entry.get("version")
        if not ver:
            continue
        if re.search(r"[-](alpha|beta|rc|dev)", ver, re.I):
            continue
        if satisfies(ver, spec):
            ok.append(entry)
    if not ok:
        return None
    ok.sort(key=lambda e: parse_version(e["version"]))
    return ok[-1]


def folder_name(namespace, name):
    # The component manager flattens espressif/* to just the name, and prefixes
    # other namespaces. Matching that keeps CMake's component lookup happy.
    return name if namespace == "espressif" else f"{namespace}__{name}"


def fetch(namespace, name, spec, seen, depth=0):
    key = f"{namespace}/{name}"
    if key in SKIP or name in SKIP:
        return
    pad = "  " * depth

    folder = os.path.join(DEST, folder_name(namespace, name))
    if key in seen:
        return
    seen.add(key)

    meta = get_json(f"{API}/{namespace}/{name}")
    entry = pick(meta, spec)
    if not entry:
        have = [v.get("version") for v in meta.get("versions", [])][-6:]
        print(f"{pad}!! {key} has nothing matching '{spec}' (latest: {have})")
        return

    version = entry["version"]

    if os.path.isdir(folder):
        print(f"{pad}== {key} {version} already vendored")
    else:
        url = entry.get("url") or entry.get("download_url")
        if not url:
            print(f"{pad}!! {key} {version} has no download url")
            return
        print(f"{pad}-> {key} {version}")
        with tempfile.TemporaryDirectory() as tmp:
            # The registry serves .zip, not .tar.gz.
            arc = os.path.join(tmp, "c.zip")
            req = urllib.request.Request(url, headers={"User-Agent": "arca-core-vendor/1"})
            with urllib.request.urlopen(req, timeout=180) as r, open(arc, "wb") as f:
                shutil.copyfileobj(r, f)
            out = os.path.join(tmp, "x")
            os.makedirs(out, exist_ok=True)
            with zipfile.ZipFile(arc) as z:
                # Refuse absolute paths and traversal before extracting.
                for nm in z.namelist():
                    if os.path.normpath(nm).startswith(("/", "..")):
                        raise RuntimeError(f"unsafe path in {key}: {nm}")
                z.extractall(out)
            inner = os.listdir(out)
            src = os.path.join(out, inner[0]) if len(inner) == 1 and os.path.isdir(
                os.path.join(out, inner[0])) else out
            os.makedirs(DEST, exist_ok=True)
            shutil.move(src, folder)

    # Recurse. Dependency metadata lives on the version entry.
    for dep in entry.get("dependencies", []) or []:
        dname = dep.get("name", "")
        # "source" is a plain string here ("service" / "idf"), not an object.
        src_kind = dep.get("source")
        if isinstance(src_kind, dict):
            src_kind = src_kind.get("type")
        if src_kind == "idf" or dname in SKIP:
            continue
        if not dep.get("require", True):
            continue
        dns = dep.get("namespace") or ("espressif" if "/" not in dname else dname.split("/")[0])
        dn = dname.split("/")[-1]
        fetch(dns, dn, dep.get("spec") or dep.get("version") or "*", seen, depth + 1)


def from_manifest():
    path = os.path.join(HERE, "main", "idf_component.yml")
    wanted = []
    with open(path) as f:
        lines = f.read().splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r"^  ([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+):\s*$", lines[i])
        if m:
            spec = "*"
            j = i + 1
            while j < len(lines) and lines[j].startswith("    "):
                vm = re.match(r'^\s*version:\s*"?([^"\n]+)"?', lines[j])
                if vm:
                    spec = vm.group(1).strip()
                    break
                j += 1
            wanted.append((m.group(1), m.group(2), spec))
        else:
            m2 = re.match(r'^  ([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+):\s*"?([^"\n]+)"?\s*$', lines[i])
            if m2 and m2.group(1) != "idf":
                wanted.append((m2.group(1), m2.group(2), m2.group(3).strip()))
        i += 1
    return wanted


def main():
    args = sys.argv[1:]
    if args:
        wanted = []
        for a in args:
            ref, _, spec = a.partition(":")
            ns, _, nm = ref.partition("/")
            wanted.append((ns, nm, spec or "*"))
    else:
        wanted = from_manifest()

    if not wanted:
        print("nothing to do - no dependencies found in main/idf_component.yml")
        return 1

    print(f"vendoring into {DEST}")
    seen = set()
    for ns, nm, spec in wanted:
        fetch(ns, nm, spec, seen)

    print(f"\n{len(seen)} component(s) resolved:")
    for name in sorted(os.listdir(DEST)) if os.path.isdir(DEST) else []:
        print(f"  components/{name}")
    print("\nNow build with the component manager off:")
    print("  IDF_COMPONENT_MANAGER=0 cmake -B build -G Ninja -DIDF_TARGET=esp32s3 .")
    return 0


if __name__ == "__main__":
    sys.exit(main())

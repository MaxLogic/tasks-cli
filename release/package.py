#!/usr/bin/env python3
"""Build portable archives from already-built, verified native binaries."""

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import tomllib
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_hashes(root):
    lines = [f"{digest(p)}  {p.relative_to(root).as_posix()}\n"
             for p in sorted(root.rglob("*")) if p.is_file() and p.name != "SHA256SUMS.txt"]
    (root / "SHA256SUMS.txt").write_text("".join(lines), encoding="utf-8")


def check_hashes(root):
    listed = set()
    for line in (root / "SHA256SUMS.txt").read_text(encoding="utf-8").splitlines():
        expected, name = line.split("  ", 1)
        path = root / name
        if not path.resolve().is_relative_to(root.resolve()):
            raise ValueError(f"Hash path escapes archive: {name}")
        if digest(path) != expected:
            raise ValueError(f"Hash mismatch: {name}")
        listed.add(name)
    actual = {p.relative_to(root).as_posix() for p in root.rglob("*")
              if p.is_file() and p != root / "SHA256SUMS.txt"}
    if actual != listed:
        raise ValueError("Hash manifest does not cover the complete archive")


def rust_notices():
    metadata = json.loads(subprocess.check_output(
        ["cargo", "metadata", "--locked", "--format-version", "1"], cwd=ROOT))
    # Include the resolved dependency graph, including build/test dependencies.
    # This deliberately over-includes notices rather than guessing which code
    # the linker retained. Source locations make absent crate license files clear.
    rust_license = (ROOT / "release/licenses/Rust-LICENSE-MIT.txt").read_text(encoding="utf-8")
    mit_terms = rust_license[rust_license.index("Permission is hereby granted"):]
    sections = ["Rust dependency notices\n\n"
                "This includes the locked default-feature dependency graph.\n"
                "Dependencies retain the licenses stated below.\n\n"
                "SQLite is in the public domain: https://sqlite.org/copyright.html\n\n"
                "Rust standard library, MIT license option:\n"
                "https://github.com/rust-lang/rust/blob/1.98.1/LICENSE-MIT\n\n" + rust_license]
    for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
        if package["source"] is None:
            continue
        base = Path(package["manifest_path"]).parent
        files = sorted({p for p in base.rglob("*") if p.is_file()
                        and p.name.lower().startswith(("license", "licence", "copying", "copyright", "notice"))})
        sections.append(f"\n{'=' * 72}\n{package['name']} {package['version']}\n"
                        f"License: {package['license'] or 'see source'}\n"
                        f"Authors: {', '.join(package['authors']) or 'see source'}\n"
                        f"Source: https://crates.io/crates/{package['name']}/{package['version']}\n"
                        f"Repository: {package.get('repository') or 'see source'}\n")
        for path in files:
            sections.append(f"\n--- {path.relative_to(base).as_posix()} ---\n"
                            + path.read_text(encoding="utf-8", errors="replace") + "\n")
        if not files and "MIT" in (package["license"] or ""):
            sections.append("\nMIT license terms (crate declares MIT but ships no license file):\n" + mit_terms)
    return "".join(sections)


def smoke(cli, commit):
    env = {k: v for k, v in os.environ.items() if not k.startswith("TASKS_")}
    version = subprocess.check_output([str(cli), "--version"], env=env, text=True).strip()
    expected_version = tomllib.loads((ROOT / "Cargo.toml").read_text())["package"]["version"]
    if version != f"tasks {expected_version} (commit {commit})":
        raise ValueError(f"Unexpected executable identity: {version}")
    with tempfile.TemporaryDirectory(prefix="tasks-release-smoke-") as temporary:
        root = Path(temporary)
        project = root / "Project with spaces"
        project.mkdir()
        body = root / "notes.md"
        body.write_text("Synthetic release check.\nAcceptance: stale edits are refused.\n")
        common = [str(cli), "--data-root", str(root / "store")]

        def run(*args, code=0):
            result = subprocess.run(common + list(args), cwd=project, env=env,
                                    capture_output=True, text=True, timeout=30)
            if result.returncode != code:
                raise ValueError(f"Smoke command {args[0]}: expected {code}, "
                                 f"got {result.returncode}: {result.stderr}")

        run("init", "--root", str(project), "--key", "DEMO")
        run("create", "--title", "Check release", "--body-file", str(body), "--status", "todo")
        run("update", "DEMO-1", "--expect-version", "1", "--status", "in-progress")
        run("update", "DEMO-1", "--expect-version", "1", "--status", "done", code=4)
        run("update", "DEMO-1", "--expect-version", "2", "--status", "to-verify")
        run("update", "DEMO-1", "--expect-version", "3", "--status", "done")
        run("show", "DEMO-1")
    return version


def archive_directory(source, destination):
    if destination.name.endswith(".zip"):
        with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(source.rglob("*")):
                if path.is_file():
                    archive.write(path, (Path(source.name) / path.relative_to(source)).as_posix())
    else:
        with tarfile.open(destination, "w:gz") as archive:
            def permissions(info):
                if info.isfile() and Path(info.name).name == "tasks":
                    info.mode |= 0o111
                return info
            archive.add(source, arcname=source.name, filter=permissions)


def extract_archive(archive, destination):
    if archive.name.endswith(".zip"):
        with zipfile.ZipFile(archive) as stream:
            for name in stream.namelist():
                if not (destination / name).resolve().is_relative_to(destination.resolve()):
                    raise ValueError(f"Unsafe archive member: {name}")
            stream.extractall(destination)
    else:
        with tarfile.open(archive) as stream:
            stream.extractall(destination, filter="data")


def package(component, platform, source, output, commit):
    version = tomllib.loads((ROOT / "Cargo.toml").read_text())["package"]["version"]
    if not re.fullmatch(r"[0-9a-f]{12,40}", commit):
        raise ValueError("Commit must be the source commit's 12-40 hexadecimal digits")
    if component == "viewer" and platform != "windows":
        raise ValueError("Only the Windows viewer is supported")
    output.mkdir(parents=True, exist_ok=True)
    name = f"tasks-{component}-{version}-{platform}-x86_64"
    destination = output / (name + (".zip" if platform == "windows" else ".tar.gz"))
    if destination.exists():
        raise ValueError(f"Archive already exists: {destination}")
    with tempfile.TemporaryDirectory(prefix="tasks-release-package-") as temporary:
        stage = Path(temporary) / name
        stage.mkdir()
        if component == "cli":
            shutil.copy2(source, stage / ("tasks.exe" if platform == "windows" else "tasks"))
        else:
            check_hashes(source)
            metadata = json.loads((source / "bundle-metadata.json").read_text())
            if metadata["launch_test"] != "passed" or metadata["source_commit"] != commit:
                raise ValueError("Viewer bundle was not launch-tested at the requested commit")
            shutil.copytree(source, stage, dirs_exist_ok=True)
            notices = stage / "data/flutter_assets/NOTICES.Z"
            (stage / "THIRD_PARTY_NOTICES-flutter.txt").write_bytes(gzip.decompress(notices.read_bytes()))
            for document in ("QUICKSTART-cli.md", "AUDIO-NOTICE.md"):
                shutil.copy2(ROOT / "release" / document, stage / document)
        shutil.copy2(ROOT / "LICENSE", stage / "LICENSE")
        shutil.copy2(ROOT / "release" / f"QUICKSTART-{component}.md", stage / "QUICKSTART.md")
        (stage / "THIRD_PARTY_NOTICES-rust.txt").write_text(rust_notices(), encoding="utf-8")
        cli = stage / ("tasks.exe" if platform == "windows" else "tasks")
        identity = smoke(cli, commit)
        (stage / "release-metadata.json").write_text(json.dumps({
            "version": version, "source_commit": commit, "cli_version": identity,
            "platform": platform, "architecture": "x86_64", "component": component,
            "linux_baseline": "Ubuntu 22.04 / glibc 2.35" if platform == "linux" else None,
        }, indent=2) + "\n", encoding="utf-8")
        write_hashes(stage)
        archive_directory(stage, destination)
        extracted = Path(temporary) / "unpacked"
        extracted.mkdir()
        extract_archive(destination, extracted)
        check_hashes(extracted / name)
        smoke(extracted / name / cli.name, commit)
    destination.with_name(destination.name + ".sha256").write_text(
        f"{digest(destination)}  {destination.name}\n", encoding="utf-8")
    print(destination)
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component", choices=("cli", "viewer"), required=True)
    parser.add_argument("--platform", choices=("windows", "linux"), required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "target/dist")
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    package(args.component, args.platform, args.input.resolve(), args.output.resolve(), args.commit)

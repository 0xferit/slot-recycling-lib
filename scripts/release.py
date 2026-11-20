"""Prepare and verify releases from a Git checkout with full main history."""

import argparse
from datetime import datetime, timezone
from http import HTTPStatus
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen
import zipfile


PROJECT = "slot-recycling-lib"
LIBRARY = "src/SlotRecyclingLib.sol"
CHANGELOG = "CHANGELOG.md"
REQUIRED_PACKAGE_DOCUMENTS = (CHANGELOG, "LICENSE", "README.md", "SECURITY.md", "STABILITY.md")
PACKAGE_PATHS = ("src", *REQUIRED_PACKAGE_DOCUMENTS, "docs/gas.md")
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
VERSION_DECLARATION = re.compile(r'(\bstring internal constant VERSION = ")([^"]+)(";)', re.ASCII)
CONVENTIONAL = re.compile(r"^([a-z]+)(?:\([^\r\n]*\))?(!)?: (.+)$")
BREAKING = re.compile(r"^(?:BREAKING CHANGE|BREAKING-CHANGE): (\S.*)$", re.MULTILINE)
COMMIT = re.compile(r"[a-f0-9]{40}")
PACKAGE_LIMIT = 10 * 1024 * 1024
REGISTRY_DELAY_SECONDS = 2
REGISTRY_ATTEMPTS = 8
REGISTRY_TIMEOUT_SECONDS = 20


def git(*args, env=None):
    return subprocess.check_output(["git", *args], env=env)


def git_text(*args, env=None):
    return git(*args, env=env).decode().strip()


def version_text(version):
    return ".".join(map(str, version))


def version_tuple(value):
    match = VERSION.fullmatch(value)
    if match is None:
        raise ValueError(f"Expected a stable semantic version, got {value!r}")
    return tuple(map(int, match.groups()))


def source_release(source):
    tags = git_text("tag", "--merged", source, "--list", "v*").splitlines()
    releases = [version_tuple(tag[1:]) for tag in tags if VERSION.fullmatch(tag[1:])]
    if not releases:
        raise ValueError("Release tags were not fetched or no stable release exists")
    return max(releases)


def source_changes(tag, source):
    changed = git("diff", "--name-only", "--no-renames", "-z", tag, source, "--", "src").decode().split("\x00")
    return any(path.endswith(".sol") for path in changed)


def changelog_entry(previous, source):
    subjects = []
    feature = False
    breaking = False
    for revision in git_text("rev-list", "--reverse", f"{previous}..{source}").splitlines():
        subject, _, body = git_text("show", "-s", "--format=%s%n%b", revision).partition("\n")
        conventional = CONVENTIONAL.fullmatch(subject)
        breaking_note = BREAKING.search(body)
        if conventional and conventional[1] == "feat":
            feature = True
        if breaking_note or (conventional and conventional[2]):
            breaking = True
        subjects.append(f"- {subject} (`{revision}`)")
        if breaking_note:
            subjects.append(f"  - Breaking change: {breaking_note[1]}")
    return feature, breaking, "\n".join(subjects)


def prepare(source):
    if not COMMIT.fullmatch(source):
        raise ValueError("Expected a full Git commit hash")
    source = git_text("rev-parse", "--verify", source + "^{commit}")
    if git_text("status", "--porcelain", "--untracked-files=no"):
        raise ValueError("Release preparation requires a clean checkout")
    previous = source_release(source)
    previous_tag = f"v{version_text(previous)}"
    if not source_changes(previous_tag, source):
        return None

    solidity = git("show", f"{source}:{LIBRARY}").decode()
    declarations = list(VERSION_DECLARATION.finditer(solidity))
    if len(declarations) != 1 or declarations[0][2] != version_text(previous):
        raise ValueError(f"Library VERSION does not match the previous release {previous_tag}")

    major, minor, patch = previous
    feature, breaking, notes = changelog_entry(previous_tag, source)
    if breaking:
        version = version_text((major + 1, 0, 0))
    elif feature:
        version = version_text((major, minor + 1, 0))
    else:
        version = version_text((major, minor, patch + 1))

    timestamp = int(git_text("show", "-s", "--format=%ct", source))
    release_date = datetime.fromtimestamp(timestamp, timezone.utc).date().isoformat()
    git("checkout", "-q", "--detach", source)
    Path(LIBRARY).write_bytes(VERSION_DECLARATION.sub(
        lambda declaration: f"{declaration[1]}{version}{declaration[3]}", solidity,
    ).encode())
    changelog = Path(CHANGELOG)
    entry = f"## {version} ({release_date})\n\n{notes}\n\n".encode()
    changelog.write_bytes(entry + changelog.read_bytes())

    git("add", "--", CHANGELOG, LIBRARY)
    tree = git_text("write-tree")
    identity = {"NAME": "github-actions[bot]",
                "EMAIL": "41898282+github-actions[bot]@users.noreply.github.com",
                "DATE": f"{timestamp} +0000"}
    env = os.environ | {f"GIT_{role}_{key}": value for role in ("AUTHOR", "COMMITTER")
                        for key, value in identity.items()}
    candidate = git_text("-c", "commit.gpgsign=false", "commit-tree", tree, "-p", source, "-m",
                         f"chore(release): {version} [skip ci]", env=env)
    git("checkout", "-q", "--detach", candidate)
    return {"commit": candidate, "source": source, "version": version}


def retry(version, main):
    version_tuple(version)
    candidate = git_text("rev-parse", "--verify", f"refs/tags/v{version}^{{commit}}")
    subprocess.run(["git", "merge-base", "--is-ancestor", candidate, main], check=True)
    parents = git_text("show", "-s", "--format=%P", candidate).split()
    if len(parents) != 1:
        raise ValueError("Expected a release tag on a single-parent release commit")
    release = prepare(parents[0])
    if release != {"commit": candidate, "source": parents[0], "version": version}:
        raise ValueError("Release tag does not match the verified release candidate")
    return release


def package_files(commit):
    files = {}
    tree = git("ls-tree", "-r", "-z", commit, "--", *PACKAGE_PATHS)
    for entry in tree.decode().split("\x00"):
        if not entry:
            continue
        metadata, path = entry.split("\t", maxsplit=1)
        mode, kind, blob = metadata.split()
        if kind != "blob" or mode not in ("100644", "100755"):
            raise ValueError(f"Non-regular file in release package: {path}")
        files[path] = git("cat-file", "blob", blob)
    if any(path not in files for path in (*REQUIRED_PACKAGE_DOCUMENTS, LIBRARY)):
        raise ValueError("Required release package files are missing")
    return files


def verify_archive(archive, expected):
    with zipfile.ZipFile(archive) as package:
        contents = [entry for entry in package.infolist() if not entry.is_dir()]
        if len(contents) != len(expected) or {entry.filename for entry in contents} != expected.keys():
            raise ValueError("Soldeer package file list does not match the release tag")
        for entry in contents:
            data = expected[entry.filename]
            entry_type = stat.S_IFMT(entry.external_attr >> 16)
            if entry_type not in (0, stat.S_IFREG) or entry.file_size != len(data) or package.read(entry) != data:
                raise ValueError(f"Soldeer package file does not match the release tag: {entry.filename}")


def open_registry_url(url):
    request = Request(url, headers={"User-Agent": f"{PROJECT} release verifier"})
    return urlopen(request, timeout=REGISTRY_TIMEOUT_SECONDS)


def registry_archive(version):
    query = urlencode({"project_name": PROJECT, "revision": version})
    try:
        with open_registry_url(f"https://api.soldeer.xyz/api/v1/revision-cli?{query}") as response:
            result = json.load(response)
    except HTTPError as error:
        if error.code == HTTPStatus.NOT_FOUND:
            with error:
                missing_revision = json.load(error)
            if missing_revision == {"message": "No revisions found", "status": "fail"}:
                return None
        raise
    if result["status"] != "success":
        raise ValueError("Soldeer registry lookup failed")
    revisions = result["data"]
    if not revisions:
        return None
    if len(revisions) != 1 or revisions[0]["version"] != version:
        raise ValueError(f"Unexpected Soldeer registry revision for {version}")
    url = urlsplit(revisions[0]["url"])
    if (url.scheme, url.netloc) != ("https", "soldeer-revisions.s3.amazonaws.com") or not (
        url.path.startswith(f"/{PROJECT}/")
    ):
        raise ValueError("Expected the package archive for this project on Soldeer storage")
    with open_registry_url(url.geturl()) as response:
        data = response.read(PACKAGE_LIMIT + 1)
    if len(data) > PACKAGE_LIMIT:
        raise ValueError("Soldeer package exceeds the release archive size limit")
    return io.BytesIO(data)


def soldeer_package(version, expected, *, dry_run=False):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory) / PROJECT
        for package_path, data in expected.items():
            path = root / package_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        command = ["forge", "soldeer", "push", f"{PROJECT}~{version}", str(root)]
        if dry_run:
            command.append("--dry-run")
        subprocess.run(command, check=True)
        if dry_run:
            verify_archive(root / f"{PROJECT}.zip", expected)


def publish_package(commit, version):
    release_notes(commit, version)
    expected = package_files(commit)
    registered = registry_archive(version)
    if registered is not None:
        verify_archive(registered, expected)
        return

    soldeer_package(version, expected)

    for attempt in range(REGISTRY_ATTEMPTS):
        registered = registry_archive(version)
        if registered is not None:
            verify_archive(registered, expected)
            return
        if attempt + 1 < REGISTRY_ATTEMPTS:
            time.sleep(REGISTRY_DELAY_SECONDS)
    raise ValueError(f"Soldeer accepted the upload command but version {version} is not visible")


def release_notes(commit, version):
    version_tuple(version)
    changelog = git("show", f"{commit}:{CHANGELOG}").decode()
    first_entry = re.split(r"\n(?=## )", changelog, maxsplit=1)[0]
    heading, _, notes = first_entry.partition("\n")
    if not heading.startswith(f"## {version} ("):
        raise ValueError(f"Release notes for {version} do not match the release candidate")
    return notes.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command, options in {
        "prepare": ("source",),
        "retry": ("version", "main"),
        "verify-package": ("commit", "archive"),
        "check-package": ("commit", "version"),
        "publish-package": ("commit", "version"),
        "notes": ("commit", "version"),
    }.items():
        sub = commands.add_parser(command)
        for option in options:
            sub.add_argument(option)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            print(json.dumps(prepare(args.source)))
        elif args.command == "retry":
            print(json.dumps(retry(args.version, args.main)))
        elif args.command == "verify-package":
            verify_archive(args.archive, package_files(args.commit))
        elif args.command == "check-package":
            release_notes(args.commit, args.version)
            soldeer_package(args.version, package_files(args.commit), dry_run=True)
        elif args.command == "publish-package":
            publish_package(args.commit, args.version)
        else:
            print(release_notes(args.commit, args.version))
    except (OSError, ValueError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()

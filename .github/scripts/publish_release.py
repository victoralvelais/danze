"""Publish the first build of a marketing version as stable and subsequent builds as prereleases."""

import json
import os
from pathlib import Path
import re
import subprocess


def api(path, *options):
    return json.loads(subprocess.check_output(["gh", "api", *options, path], text=True))


def tag_commit(repo, tag):
    refs = api(f"repos/{repo}/git/matching-refs/tags/{tag}")
    for ref in refs:
        if ref["ref"] == f"refs/tags/{tag}":
            obj = ref["object"]
            return obj["sha"] if obj["type"] == "commit" else api(f"repos/{repo}/commits/{tag}")["sha"]
    return None


def has_asset(release, filename):
    return any(a["name"] == filename and a["state"] == "uploaded" and a["size"] > 0 for a in release["assets"])


def version_of(tag):
    # Historical build-qualified releases also count when comparing Latest.
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)(?:-build\.\d+)?", tag)
    return tuple(map(int, match.groups())) if match else ()


def main():
    repo, commit = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"]
    version, build = os.environ["VERSION"], os.environ["GITHUB_RUN_NUMBER"]
    filename = os.environ["FILENAME"]
    ipa = str(Path(os.environ["RUNNER_TEMP"]) / filename)
    title = f"{os.environ['APP']} {version} (build {build})"
    stable = f"v{version}"
    dev = f"{stable}-build.{build}"
    pages = api(f"repos/{repo}/releases?per_page=100", "--paginate", "--slurp")
    releases = {r["tag_name"]: r for page in pages for r in page}

    # A rerun of a build always reuses its own release, including an interrupted draft.
    tag = dev if dev in releases else stable
    target = tag_commit(repo, tag)
    existing = releases.get(tag)
    if tag == stable and existing:
        owned = (existing["draft"] and existing["target_commitish"] == commit and existing["name"] == title
                 or not existing["draft"] and target == commit and (existing["name"] == title or has_asset(existing, filename)))
        if not owned:
            tag = dev
    elif tag == stable and target is not None and target != commit:
        tag = dev
    if tag == dev:
        print(f"::notice::Publishing development build {tag}. Bump MARKETING_VERSION for the next stable release.", flush=True)
        target = tag_commit(repo, tag)
    existing = releases.get(tag)
    if target is not None and target != commit:
        raise RuntimeError(f"Tag {tag} already points at another commit")
    if existing and not existing["draft"]:
        if target != commit or not has_asset(existing, filename):
            raise RuntimeError(f"Published release {tag} does not match this build")
        print(f"Verified existing published IPA on {tag}.")
        return

    highest = max((version_of(r["tag_name"]) for r in releases.values()
                   if not r["draft"] and not r["prerelease"]), default=())
    latest = tag == stable and version_of(stable) >= highest
    flags = [f"--latest={str(latest).lower()}"]
    if tag == dev:
        flags.append("--prerelease")
    if existing:
        if existing["target_commitish"] != commit or existing["name"] != title:
            raise RuntimeError(f"Draft {tag} belongs to a different build")
        subprocess.run(["gh", "release", "upload", tag, ipa, "--clobber"], check=True)
        subprocess.run(["gh", "release", "edit", tag, "--draft=false", *flags], check=True)
    else:
        subprocess.run(["gh", "release", "create", tag, ipa, "--target", commit, "--title", title,
                        "--notes", f"LiveContainer IPA from commit {commit}.", *flags], check=True)


if __name__ == "__main__":
    main()

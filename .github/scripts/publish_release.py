"""Choose a semantic version before compiling and publish one immutable IPA per version."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys


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
    match = re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag)
    return tuple(map(int, match.groups())) if match else ()


def choose_version(requested, releases, commit):
    base = version_of("v" + requested)
    if not base:
        raise ValueError(f"Invalid project version {requested!r}")
    published = []
    for release in releases:
        version = version_of(release["tag_name"])
        if not version or release["prerelease"]:
            continue
        if release["target_commitish"] == commit:
            return release["tag_name"][1:]
        published.append(version)
    latest = max(published, default=())
    if latest >= base:
        base = (latest[0], latest[1], latest[2] + 1)
    return ".".join(map(str, base))


def main():
    repo, commit = os.environ["GITHUB_REPOSITORY"], os.environ["GITHUB_SHA"]
    pages = api(f"repos/{repo}/releases?per_page=100", "--paginate", "--slurp")
    releases = [r for page in pages for r in page]
    if len(sys.argv) == 3 and sys.argv[1] == "--select-version":
        print(choose_version(sys.argv[2], releases, commit))
        return
    version = os.environ["VERSION"]
    filename = os.environ["FILENAME"]
    if not version_of("v" + version) or filename != f"{os.environ['APP']}-v{version}.ipa":
        raise ValueError("Unexpected release version or IPA filename")
    ipa = str(Path(os.environ["RUNNER_TEMP"]) / filename)
    title, tag = f"Dance Camera {version}", f"v{version}"
    target = tag_commit(repo, tag)
    existing = next((r for r in releases if r["tag_name"] == tag), None)
    if target is not None and target != commit:
        raise RuntimeError(f"Tag {tag} already points at another commit")
    if existing and not existing["draft"]:
        if existing["prerelease"] or target != commit or not has_asset(existing, filename):
            raise RuntimeError(f"Published release {tag} does not match this build")
        print(f"Verified existing published IPA on {tag}.")
        return

    highest = max((version_of(r["tag_name"]) for r in releases
                   if not r["draft"] and not r["prerelease"]), default=())
    latest = version_of(tag) >= highest
    flags = [f"--latest={str(latest).lower()}"]
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

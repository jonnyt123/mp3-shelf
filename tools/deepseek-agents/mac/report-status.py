#!/usr/bin/env python3
"""Root-only Mac status broker. Never runs code from checked-out agent branches."""
import datetime
import json
import os
import pathlib
import re
import sys
import tempfile
import urllib.error
import urllib.request

ROOT = pathlib.Path("/Library/Application Support/MP3ShelfCloudQA")
CONFIG = ROOT / "reporter.json"
TOKEN = ROOT / "status-token"
HISTORY = ROOT / "posted.json"
GATE = pathlib.Path("/Library/Application Support/MP3ShelfGate")
ROLES = {"mp3-playback","mp3-sources","mp3-ui","mp3-qa","mp3-integration"}

def record_qa_result(role, sha, status):
    """Publication-proof QA receipt, written only by the root status broker AFTER GitHub ACK."""
    GATE.mkdir(mode=0o755, parents=True, exist_ok=True)
    st = GATE.lstat()
    if not GATE.is_dir() or GATE.is_symlink() or st.st_uid != 0 or (st.st_mode & 0o022):
        raise RuntimeError("Unsafe root QA evidence directory")
    GATE.chmod(0o755)  # Nonsecret QA receipts are readable to the unprivileged coordinator.
    evidence = {
        "schema": 1, "role": role, "sha": sha, "status": status,
        "githubContext": "mp3/mac-xcode",
        "check": "unsigned-simulator-build-and-Swift-regressions",
        "physicalIphone": "NOT_TESTED"
    }
    fd, temp = tempfile.mkstemp(prefix=".qa-" + role + "-", dir=GATE)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(json.dumps(evidence, sort_keys=True) + "\n")
        os.chmod(temp, 0o644)
        os.replace(temp, GATE / ("qa-" + role + ".json"))
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def main():
    if os.geteuid() != 0:
        raise RuntimeError("Reporter must run as root, separate from Xcode jobs")
    if not TOKEN.is_file() or not CONFIG.is_file():
        print("No Mac status token/config installed; skipping")
        return
    cfg = json.loads(CONFIG.read_text())
    reports = pathlib.Path(cfg["reports"]).resolve()
    if not reports.is_dir():
        print("Reports directory unavailable")
        return
    token = TOKEN.read_text().strip()
    if not re.fullmatch(r"[A-Za-z0-9_]+", token) or len(token) < 25:
        raise RuntimeError("Invalid status token format")
    posted = json.loads(HISTORY.read_text()) if HISTORY.is_file() else {}
    for role in sorted(ROLES):
        file = reports / (role + ".json")
        if file.is_symlink() or not file.is_file():
            continue
        data = json.loads(file.read_text())
        sha = data.get("sha")
        status = data.get("status")
        if data.get("role") != role or not isinstance(sha, str) or not re.fullmatch(r"[a-f0-9]{40}", sha) or status not in {"success","failure"}:
            print("Ignoring malformed report for",role)
            continue
        key = role + ":" + sha + ":" + status
        if posted.get(role) == key:
            # A prior successful GitHub POST may predate receipt support.
            receipt = GATE / ("qa-" + role + ".json")
            if not receipt.is_file() or receipt.is_symlink():
                record_qa_result(role, sha, status)
            continue
        # Verify SHA exists in the exact GitHub repository before writing a status.
        api = "https://api.github.com/repos/jonnyt123/mp3-shelf/statuses/" + sha
        body = json.dumps({
            "state": status,
            "context": "mp3/mac-xcode",
            "description": "Unsigned simulator build + Swift regressions " + status + "; physical iPhone NOT tested"
        }).encode()
        request = urllib.request.Request(api, data=body, method="POST", headers={
            "Authorization": "Bearer " + token,
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
            "User-Agent": "MP3Shelf-Independent-Mac-QA"
        })
        try:
            # Confirm GitHub branch HEAD is the exact SHA tested, not merely a valid
            # repository object. Never mark an obsolete or arbitrary SHA as current QA.
            ref_url = ("https://api.github.com/repos/jonnyt123/mp3-shelf/"
                       "git/ref/heads/agent/" + role)
            check = urllib.request.Request(ref_url,headers={
                "Authorization": "Bearer " + token,
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "MP3Shelf-Independent-Mac-QA"
            })
            with urllib.request.urlopen(check,timeout=25) as response:
                ref = json.load(response)
            if ref.get("object", {}).get("sha") != sha:
                print("Skipping outdated QA SHA for",role)
                continue
            with urllib.request.urlopen(request,timeout=25) as response:
                if response.status != 201:
                    raise RuntimeError("Unexpected GitHub response")
            posted[role] = key
            tmp = HISTORY.with_suffix(".tmp")
            tmp.write_text(json.dumps(posted,indent=2))
            os.chmod(tmp,0o600)
            os.replace(tmp,HISTORY)
            record_qa_result(role,sha,status)
            print("Reported",role,sha[:12],status)
        except urllib.error.HTTPError as e:
            print("GitHub API error for",role,e.code,file=sys.stderr)
            # Continue; retry on next reporter invocation.
if __name__ == "__main__":
    main()

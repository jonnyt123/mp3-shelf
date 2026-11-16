#!/bin/bash
# One-time user-level launchd installation. No root, paid CI or credential creation.
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo "MP3 Shelf native auto-build requires a Mac with Xcode." >&2
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
NODE="$(command -v node || true)"
[[ -n "$NODE" && -f "$ROOT/scripts/native-release-cycle.mjs" ]] || {
  echo "Node.js 20+ and the release-tooling repository checkout are required." >&2; exit 2;
}
xcodebuild -version >/dev/null
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null
if ! git -C "$ROOT" remote get-url origin | grep -Eq 'github[.]com[:/]jonnyt123/mp3-shelf([.]git)?$'; then
  echo "This checkout must point to jonnyt123/mp3-shelf on GitHub." >&2
  exit 2
fi
AGENT="com.jonnyt.mp3shelf.native-preflight"
DEST="$HOME/Library/LaunchAgents/$AGENT.plist"
LOGS="$HOME/Library/Logs/MP3Shelf"
mkdir -p "$HOME/Library/LaunchAgents" "$LOGS"
# Use plistlib to handle spaces/ampersands and avoid shell-generated XML.
python3 - "$DEST" "$NODE" "$ROOT" "$LOGS" <<'PY'
import os, plistlib, sys
dest, node, root, logs = sys.argv[1:]
arguments = [node, os.path.join(root, "scripts", "native-release-cycle.mjs"), root]
if os.path.exists(dest):
    with open(dest, "rb") as f:
        old = plistlib.load(f)
    if old.get("Label") != "com.jonnyt.mp3shelf.native-preflight" or not \
            any(str(x).endswith(("mac-native-candidate.mjs", "native-release-cycle.mjs"))
                for x in old.get("ProgramArguments", [])):
        raise SystemExit("Refusing to overwrite an unrelated LaunchAgent")
plist = {
    "Label": "com.jonnyt.mp3shelf.native-preflight",
    "ProgramArguments": arguments,
    "WorkingDirectory": root,
    # launchd does not inherit an interactive Terminal PATH. Include the
    # installed Node directory and standard Apple Silicon/Intel Homebrew
    # locations so git, xcodebuild, swift, python3 and an existing gh login
    # can be found without embedding any credential in the plist.
    "EnvironmentVariables": {"PATH": os.pathsep.join(dict.fromkeys([
        os.path.dirname(node), "/opt/homebrew/bin", "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin"
    ]))},
    "RunAtLoad": True,
    "StartInterval": 3600,
    "StandardOutPath": os.path.join(logs, "native-preflight.stdout.log"),
    "StandardErrorPath": os.path.join(logs, "native-preflight.stderr.log"),
    "ProcessType": "Background",
}
temporary = dest + ".new"
with open(temporary, "wb") as f:
    plistlib.dump(plist, f, sort_keys=True)
os.chmod(temporary, 0o600)
os.replace(temporary, dest)
PY
LABEL="gui/$(id -u)/$AGENT"
launchctl bootout "$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$DEST"
launchctl kickstart -k "$LABEL"
echo "Installed: $AGENT (hourly and at login)."
echo "This runs the native Xcode verifier against a temporary candidate checkout."
echo "Promotion is NON-FORCE to draft PR #29 only, after exact-SHA tests."
echo "After physical issue #6 and evidence approval, the cycle writes a verified Xcode ZIP and manifest."
echo "Full logs: $LOGS. Physical-iPhone acceptance remains separate."

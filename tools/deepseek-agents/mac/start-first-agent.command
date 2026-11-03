#!/bin/bash
# Finder one-click, single paid Playback agent cycle with read-only balance preflight.
# No manual shell commands, no extra agents, and no automatic queue continuation.
set -Eeuo pipefail
umask 077
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ROOT="$HOME/MP3ShelfAgents"
CLIENT="$ROOT/tools/deepseek-agents/cloudflare/mac-client.mjs"
PLIST="$HOME/Library/LaunchAgents/com.mp3shelf.cloud-coordinator.plist"
LAUNCH_DOMAIN="gui/$(id -u)"
PAUSED_BY_US=0
RESTORE_SERVICE=0

dialog() {
  /usr/bin/osascript - "$1" "$2" <<'OSA'
on run argv
  display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button "OK" with icon note
end run
OSA
}
exit_handler() {
  local code="$?"
  trap - EXIT
  if (( PAUSED_BY_US == 1 )); then
    node "$CLIENT" --pause >/dev/null 2>&1 || echo "Warning: Cloudflare pause could not be confirmed. Check dashboard before resuming." >&2
  fi
  if (( RESTORE_SERVICE == 1 )); then
    /bin/launchctl bootstrap "$LAUNCH_DOMAIN" "$PLIST" >/dev/null 2>&1 ||
      echo "Warning: background coordinator could not restart; rerun the Mac setup installer." >&2
  fi
  if (( code != 0 )); then
    dialog "MP3 Shelf — First Run Incomplete" "The first coding cycle did not finish successfully. Check the Terminal window for the error. Cloudflare was instructed to pause; no additional coding jobs were intentionally started." || true
  fi
  if [[ -t 0 ]]; then printf '\nYou may close this Terminal window.\n'; fi
  exit "$code"
}
trap exit_handler EXIT
if [[ "$(uname -s)" != "Darwin" || "$EUID" -eq 0 ]]; then
  echo "Open this file as your normal macOS user." >&2; exit 1
fi
if [[ ! -f "$CLIENT" || ! -f "$PLIST" ]]; then
  echo "MP3 Shelf is not installed. Double-click Install MP3 Shelf.command first." >&2;exit 1
fi
if ! command -v node >/dev/null; then
  echo "Node.js 22+ is missing. Double-click Install MP3 Shelf.command." >&2;exit 1
fi
if ! grep -q -- '--first-only' "$CLIENT"; then
  echo "The locally installed agent code predates first-run mode. Reopen the updated Mac installer." >&2;exit 1
fi
printf 'MP3 Shelf — first coding agent\n'
printf 'No DeepSeek model call is made until a valid balance has been checked and you approve it.\n'
printf '\n[1/5] Checking the locally configured DeepSeek Console account (read-only)...\n'
DOCTOR="$(node "$CLIENT" --doctor)"
export MP3_FIRST_DOCTOR="$DOCTOR"
read -r AMOUNT CURRENCY <<< "$(node -e '
const d=JSON.parse(process.env.MP3_FIRST_DOCTOR);
if(!d.coordinatorConnected || !d.apiAvailable || !Number.isFinite(d.apiBalance) || d.apiBalance<0.25) {
  console.error("DeepSeek balance unavailable or below the minimum 0.25 in the account currency");
  process.exit(1)
}
console.log(d.apiBalance.toFixed(2)+" "+d.balanceCurrency)
')"
unset DOCTOR MP3_FIRST_DOCTOR
if [[ -z "$AMOUNT" || -z "$CURRENCY" ]]; then
  echo "Could not confirm your DeepSeek balance. No model request was started." >&2;exit 1
fi
printf 'DeepSeek available balance: %s %s (verified without model usage)\n' "$AMOUNT" "$CURRENCY"

printf '\n[2/5] Confirming the first Playback job is ready...\n'
STATUS="$(node "$CLIENT" --status)"
MP3_FIRST_STATUS="$STATUS" node -e '
const s=JSON.parse(process.env.MP3_FIRST_STATUS);
if(Number(s.counts?.leased||0)>0) {console.error("Another agent job is already leased.");process.exit(1)}
const first=(s.roleStates||[]).find(x=>x.role==="mp3-playback"&&Number(x.cycle)===0);
if(!first||first.state!=="queued"||Number(first.attempts)!==0) {
  console.error("First Playback job is not fresh and queued. No duplicate work will start.");process.exit(1);
}
'
unset STATUS

# Explicit payment consent immediately before any resume or lease.
if ! /usr/bin/osascript - "$AMOUNT" "$CURRENCY" <<'OSA'
on run argv
  set balance to item 1 of argv
  set currency to item 2 of argv
  set explanation to "DeepSeek reports " & balance & " " & currency & " available. Run ONE paid MP3 Shelf Playback coding session? The local observed spend limit defaults to 0.50 account-currency units per day, but this is a soft cap, not a guarantee. The Cloudflare queue will return to PAUSED after claiming the job. No production merge will be performed."
  set answer to display dialog explanation with title "MP3 Shelf — Authorize First Agent" buttons {"Cancel", "Run One Agent"} default button "Cancel" with icon caution
  if button returned of answer is not "Run One Agent" then error number -128
end run
OSA
then
  echo "No paid request approved. Nothing started."
  exit 0
fi

printf '\n[3/5] Pausing the multi-agent queue before isolating the first run...\n'
node "$CLIENT" --pause >/dev/null
PAUSED_BY_US=1
CURRENT="$(node "$CLIENT" --status)"
MP3_FIRST_STATUS="$CURRENT" node -e '
const s=JSON.parse(process.env.MP3_FIRST_STATUS);
if(!s.paused||Number(s.counts?.leased||0)!==0) {
 console.error("Queue is not safely paused or another agent is active.");process.exit(1);
}
'
unset CURRENT
if /bin/launchctl print "$LAUNCH_DOMAIN/com.mp3shelf.cloud-coordinator" >/dev/null 2>&1; then
  /bin/launchctl bootout "$LAUNCH_DOMAIN" "$PLIST"
  RESTORE_SERVICE=1
fi

printf '\n[4/5] Starting exactly one Playback coding cycle; the queue will pause after lease...\n'
MP3_FIRST_CYCLE_EXCLUSIVE=1 node "$CLIENT" --first-only
printf '\n[5/5] First cycle returned; Cloudflare will remain paused.\n'
dialog "MP3 Shelf — First Run Finished" "The first agent returned from its coding session. See the Terminal window for its result and the Cloudflare dashboard for the recorded job. The queue stays paused until you choose otherwise."

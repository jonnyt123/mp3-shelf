# MP3 Shelf — DeepSeek low-cost development workers

> **Preferred free/no-card setup:** Cloudflare Workers Free + D1 for the queue and your Mac for coding/Xcode. Oracle is optional and not required. See [Cloudflare setup](cloudflare/README.md) and the [single Mac installer](mac/setup-all.sh). The server and Mac services are **not activated by committing these files**.

### Simplified one-time activation

**One guided command, no Cloudflare resource creation.** The connected account already has `mp3-shelf-coordinator`, D1 database `mp3-shelf-agent-jobs`, and five paused jobs. This Mac installer reuses them.

On first run, the installer will:
1. Check Xcode and Git, and install Node.js 22+ / OpenCode V2 via Homebrew when missing (with your permission for Homebrew installation if necessary).
2. Run all offline regression checks before touching credentials.
3. Open Cloudflare browser sign-in only if necessary; rotate the Cloudflare coordinator bearer token into a protected local file (or reuse one that already works).
4. Use the known dashboard URL automatically and request your DeepSeek API key once through hidden terminal input (reuse on future runs).
5. Install the Mac coordinator, protected draft-PR publisher, unsigned Xcode QA runner and separate GitHub QA status reporter.
6. Run read-only Cloudflare/DeepSeek diagnostics and print the exact dashboard and pause/resume instructions.

Two limited GitHub fine-grained tokens still need to be entered locally the **first** time: Contents+Pull requests write for PR creation; Commit statuses write for test reporting. They are stored root-only and not supplied to coding agents. Authentication can't be silently bypassed. The installation does **not** run paid model requests or merge changes, and remains paused until you explicitly resume.



On your Mac, after installing Node.js 22+, Xcode, Git and OpenCode 2, open a clone of branch `agent/mp3-deepseek-low-cost-worker` and run:

```bash
bash tools/deepseek-agents/mac/setup-all.sh
```

The installer checks offline tests, deploys the free Cloudflare Worker + D1, collects keys privately on your Mac, installs a separate root-protected GitHub draft publisher, Mac Xcode QA poller and status-only reporter, and performs a **read-only** DeepSeek account balance check. It starts **paused**. Two narrow GitHub fine-grained PATs are required: one with Contents and Pull requests write for draft publishing; one with Commit statuses write for Mac QA evidence. Keep them out of chat.

After inspecting the dashboard and checking that the DeepSeek API balance is positive, resume the coordinator with `node tools/deepseek-agents/cloudflare/mac-client.mjs --resume`. The user-level launchd agent starts claiming tasks while the Mac is awake. A fully completed *live* cycle still requires a genuine DeepSeek call, local commit, published draft PR, and Xcode result. None of that has been performed in this conversation.



This directory contains the **prepared** worker. It is NOT a running cloud service yet. It requires a persistent trusted host, a DeepSeek Console API key with available balance, Git and OpenCode. It makes no OpenAI API calls, uses no ChatGPT scheduled tasks, and does not trigger GitHub Actions.

The five profiles in .opencode/agents/ use the same DeepSeek Console account and DeepSeek Flash model. They execute sequentially (one paying agent at a time) in five separate persistent worktrees.

## Prerequisites

1. Node.js 22+, Git and current OpenCode on a trusted Linux/macOS host. A Mac with Xcode is required for genuine iOS builds.
2. A DeepSeek Console API key in the host SECRET environment variable DEEPSEEK_API_KEY. Never paste keys into chat or commit them. Free DeepSeek chat does not imply free API balance.
3. Git access to https://github.com/jonnyt123/mp3-shelf and checkout of branch agent/mp3-deepseek-low-cost-worker. This branch contains the native PR #4 baseline and these agent definitions.
4. A sandboxed, persistent host with controlled costs. This repository does NOT provision hosting.

## Run from the repository root

    node tools/deepseek-agents/runner.mjs --dry-run
    node --test tools/deepseek-agents/runner.test.mjs
    node tools/deepseek-agents/runner.mjs --status
    node tools/deepseek-agents/runner.mjs --once
    node tools/deepseek-agents/runner.mjs --loop

The --status command makes the read-only GET https://api.deepseek.com/user/balance request. --once runs one bounded coding session. --loop runs indefinitely *only while an external host process remains active*; it is not a ChatGPT scheduled task.

## Conservative resource policy

- MP3_AGENT_DAILY_CAP=0.50 (default): local maximum observed daily spend, in the DeepSeek account's native balance currency (USD or CNY).
- MP3_AGENT_MIN_BALANCE=0.25: do not begin a paid session if less remains.
- MP3_AGENT_MAX_RUN_SECONDS=480: terminate an excessively long paid worker.
- MP3_AGENT_IDLE_SECONDS=900: interval between sequential sessions.
- MP3_AGENT_BASE_REF=agent/mp3-deepseek-low-cost-worker: initial branch for new worker worktrees, descended from the existing native PR #4.
- MP3_AGENT_ROLE=mp3-playback (optional): select one of five named roles instead of rotation.

The local budget is a **soft** protection. An in-flight request can exceed it; account balance updates can lag; other clients may also consume the same balance. A hard spending cap requires provider-side enforcement or a metering gateway. Currency changes, missing key, no available balance, dirty worktrees and file scope violations fail closed.

Stable system prompts benefit from automatic DeepSeek context prefix caching. Profiles inspect only relevant files, the current milestone and small diffs, avoid whole-repository dumps, prefer local focused tests, and do not escalate to a more expensive model. This does NOT use five parallel API calls.

## Git safety and release restrictions

Worktrees: ../mp3-shelf-agent-worktrees/ (one per specialist).
Private ledger and lock: ../.mp3-shelf-agent-state/.
After a coding session, the supervisor verifies file ownership and diff formatting and makes a LOCAL COMMIT only. It never pushes, creates PRs, merges to main, spends on Actions, or deploys. If a worker fails or changes outside its scope, the code is retained for review and not committed. A separate trusted publishing/integration service must be added before remote unattended changes are enabled.

The original native PRs #1 to #4 are stacked draft PRs. Do not ship to main until real signed iPhone hardware acceptance is recorded at https://github.com/jonnyt123/mp3-shelf/issues/6. Simulator evidence is not physical-device evidence.

Run the worker only in a restricted environment. OpenCode's command permissions are not a substitute for OS-level isolation, and the DeepSeek API key remains sensitive. GitHub credentials must be managed separately by the trusted supervisor, not handed to coding children.

The Node test suite covers file ownership, path guards, ledger rollover and mocked balance calls. It does not make paid model requests or claim that native iPhone QA is complete.

## One-time OCI Always Free VM setup (not yet provisioned)

Choose an **Always Free eligible** Ubuntu 24.04 Arm instance, e.g. VM.Standard.A1.Flex with 1 OCPU and 6 GB RAM, and an Always Free eligible boot volume in your Oracle home region. Verify the final console estimate reads $0. Do not select paid capacity or enable billable upgrades. Oracle may have no free capacity available; abort instead of choosing paid capacity. This repository cannot open an Oracle tenant or create a VM; those steps require an authenticated OCI administrator.

On a freshly provisioned VM, in its own SSH terminal (never paste keys into ChatGPT):

    sudo apt-get update && sudo apt-get install -y git
    git clone --depth 1 --branch agent/mp3-deepseek-low-cost-worker https://github.com/jonnyt123/mp3-shelf.git /tmp/mp3-shelf-bootstrap
    sudo bash /tmp/mp3-shelf-bootstrap/tools/deepseek-agents/oci/bootstrap-ubuntu.sh
    sudo bash /srv/mp3-shelf/tools/deepseek-agents/oci/install-secret.sh
    sudo bash /srv/mp3-shelf/tools/deepseek-agents/oci/check-and-start.sh

The bootstrap installs Node 22, Git, OpenCode 2, a dedicated non-login service user and a hardened systemd service. It does NOT enable that service. The secret installer writes a protected root-only /etc/mp3-shelf/agent.env. The final script verifies the offline guard tests and checks the **real** DeepSeek API balance (read-only) before enabling the persistent worker. It does NOT provide DeepSeek credits.

To inspect or stop:

    sudo systemctl --no-pager status mp3-shelf-agent
    sudo journalctl -u mp3-shelf-agent --since '1 hour ago' --no-pager
    sudo systemctl disable --now mp3-shelf-agent

The worker cannot build signed iPhone apps on Oracle Linux. That verification still requires macOS/Xcode, and the physical-iPhone release gate #6 remains mandatory. Successful first agent activation means a real DeepSeek-driven coding session ran with enough API balance on the actual server; local code edits and test evidence must be checked before anyone claims a shippable result. This first stage deliberately makes local commits only; no remote PRs or automatic releases are enabled.


## Q2 — automatic guarded draft PR publishing

A separate publishing broker is provided in tools/deepseek-agents/publish.mjs. The Oracle setup installs a **root-owned copy** under /opt/mp3-shelf-publisher, running as a different Linux user (mp3publisher). The DeepSeek model process has no GitHub token. The broker never executes agent-supplied code.

Obtain a GitHub fine-grained PAT limited to only jonnyt123/mp3-shelf with Contents read/write and Pull requests read/write. Enter it in hidden input on the server:

    sudo bash /srv/mp3-shelf/tools/deepseek-agents/oci/install-publisher-token.sh
    sudo systemctl enable --now mp3-shelf-publisher.path

The systemd path watcher triggers when the coding supervisor writes approved SHA-bound evidence. The supervisor checks file ownership, Git diff hygiene, Node unit tests, and web tests/typecheck when applicable. The broker double-checks the exact SHA, per-commit file list, expected ancestry, and non-force push semantics. It publishes only agent/mp3-* branches and opens DRAFT PRs against the dedicated agent setup branch (which itself is based on draft native PR #4).

Agent commits include [skip ci] to avoid consuming exhausted GitHub Actions minutes. GitHub may leave required checks pending; this is intentional and does not bypass or mark them green. Mac QA checks must happen independently before merging and the real iPhone release gate #6 still blocks merging the original stacked native changes to main.

Stop remote publishing (agents may still make local commits):

    sudo systemctl disable --now mp3-shelf-publisher.path
    sudo systemctl stop mp3-shelf-publisher.service

## Q3 — Mac Xcode QA companion

Use your existing Mac with Xcode as the native build worker. It does not need inbound SSH, an externally exposed port, a DeepSeek API key, or a GitHub Actions runner.

In a clone of the setup branch on your Mac:

    bash tools/deepseek-agents/mac/install-mac.sh

The Mac LaunchAgent fetches updated agent branches from GitHub while the Mac is awake/logged in. For every new SHA it performs an unsigned Simulator Debug build and five Swift regression suites, then writes reports under ~/Library/Application Support/MP3ShelfCloudQA/.

Optional automated GitHub commit statuses use a DIFFERENT, root-only macOS LaunchDaemon:

    sudo bash tools/deepseek-agents/mac/install-status-reporter.sh

It asks for a distinct fine-grained GitHub PAT with Commit statuses write (and Contents read) for only mp3-shelf, stored root-only at /Library/Application Support/MP3ShelfCloudQA/status-token. The test processes never receive that token. The broker publishes mp3/mac-xcode SUCCESS/FAILURE on the exact tested commit. These are unsigned Simulator results, **not physical iPhone evidence**. QA reports are local data and cannot authorize an automatic main merge.

To inspect and stop the Mac worker:

    launchctl list | grep com.mp3shelf.cloudqa
    tail -n 40 "$HOME/Library/Application Support/MP3ShelfCloudQA/launch-out.log"
    launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.mp3shelf.cloudqa.plist"

## Activation boundary

No Oracle VM, DeepSeek credentials, actual account balance, GitHub PATs, or user Mac Xcode execution are accessible to this chat. All of these components are PREPARED IN SOURCE but NOT ACTIVATED. Do not claim autonomous paid agent execution, Mac pass evidence, or remote publishing until those external prerequisites exist and a real first end-to-end execution has been observed. These are host-level systemd/launchd services, not ChatGPT scheduled tasks; all Aethermoor ChatGPT tasks remain untouched.

**Branch topology:** Native draft PR #4 (`feat/ios-premium-visual-refresh`) → agent setup PR (`agent/mp3-deepseek-low-cost-worker`) → five separate agent branches and DRAFT PRs. The GitHub publishing broker targets the agent setup branch, not native PR #4 directly. Integration into native PR #4 waits for separate review and Mac QA; merging native PRs to main still requires issue #6's physical-device gate.

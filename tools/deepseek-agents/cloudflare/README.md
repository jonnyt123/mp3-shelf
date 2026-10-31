# MP3 Shelf — Cloudflare Workers Free coordinator

**Purpose:** Cloudflare Workers Free + D1 is the small, durable *control plane* for five DeepSeek coding roles. The **Mac** does actual repository inspection, model API calls, code edits, tests and local commits. Cloudflare does not run Xcode or an AI model and holds **no DeepSeek or GitHub API keys**.

**No Oracle VM, billing card, paid Cloudflare subscription, GitHub Actions minutes, or ChatGPT scheduled tasks required.** You still need an existing DeepSeek API key with API credits (or a compatible local model as a future replacement). An awake, logged-in Mac executes jobs; it stops when the Mac sleeps and resumes on wake/login.

## Free plan and safety

- Workers Free: 100,000 requests/day, 10 ms CPU time/request.
- D1 Free: 5 million rows read/day, 100,000 rows written/day and 5 GB account storage (maximum 500 MB per database).
- The queue uses a few SQL statements per request, not a continuously running VM. Free-tier exhaustion fails requests; it does not silently convert the account to Workers Paid.
- One Mac runs one DeepSeek session at a time. The existing runner enforces its own *soft* daily token-spend observation and model duration limit. A provider-side hard cap must be configured separately for guaranteed spend limits.
- Five allowlisted roles only; no arbitrary commands or prompts accepted from the public HTTP API.
- A 256-bit shared bearer token protects queue, status, and pause actions. Secrets are stored at rest only in Cloudflare's secret store and the local Mac user's chmod-0600 credentials file, outside the repo.
- Server starts **paused**. The Mac user must explicitly choose to resume it.
- Lease duration: 45 minutes. Two failed attempts block a job instead of repeatedly spending DeepSeek credits. Deferred jobs resume after an hour. Successfully committed milestones queue their next cycle automatically; unchanged work stops its role.
- No automatic production deployments or merges. Draft native PRs #1–#4 and hardware sign-off issue #6 remain protected.

## One-time Cloudflare deployment

You need a **Free Cloudflare account**; sign up at https://dash.cloudflare.com/sign-up (Cloudflare states no credit card needed). Use your existing Apple Silicon Mac with Node.js 22+, Git, Xcode and OpenCode 2.

In a local checkout of branch **agent/mp3-deepseek-low-cost-worker**:

    bash tools/deepseek-agents/cloudflare/deploy-free.sh

The script:
1. Installs the project's Wrangler CLI dependency.
2. Opens Cloudflare login through Wrangler if necessary.
3. Deploys the Worker on a Cloudflare-provided workers.dev address; Wrangler automatically provisions the free D1 binding.
4. Applies the D1 SQL migration to the **remote** database.
5. Generates a 256-bit coordinator token locally (if absent) and uploads it to Cloudflare using the encrypted Worker secret facility.

The token is generated to:

    ~/Library/Application Support/MP3ShelfCloudCoordinator/coordinator-token

It is not committed to GitHub, sent to chat, or shown in the console. Record the workers.dev URL printed by Wrangler. The Worker **does not need a domain name**.

## One-time Mac connection

On the same Mac, in the same repository:

    bash tools/deepseek-agents/cloudflare/install-mac-coordinator.sh

Enter the Cloudflare workers.dev URL and your DeepSeek API key through hidden terminal input. The script creates a local chmod-0600 credentials file outside the Git repository:

    ~/Library/Application Support/MP3ShelfCloudCoordinator/credentials.json

It checks the remote coordinator, seeds five roles, and installs a local launchd service that connects only **outbound** to Cloudflare. No public SSH, Cloudflare Tunnel, API gateway subscription, or GitHub Actions runner is required.

The service begins **paused**, even after installation. After checking your DeepSeek account balance and the worker logs, enable it explicitly:

    node tools/deepseek-agents/cloudflare/mac-client.mjs --resume

Then the Mac claims work sequentially, calls the existing locally guarded DeepSeek/OpenCode runner, and sends completion/deferral/failure back to Cloudflare. No human replies are required for routine continuation while the Mac is running and API balance remains sufficient.

## Premium no-card dashboard

After deploying the Cloudflare Worker, open the **workers.dev URL** displayed by Wrangler in Safari or any modern browser. A mobile-friendly control center is served at the root path. It displays five agent roles, queue counts, last successful Mac heartbeat, recent jobs, completion status, and a pause/resume control. Blocked tasks show a manual retry button. The dashboard does not store the coordinator token in cookies, localStorage or analytics—it lives only in the open tab's memory and must be entered again after reload. Retrieve the token from the locally protected `coordinator-token` file created by deployment. Do not share it publicly; this token authorizes pausing and claiming jobs.

The dashboard starts **paused** until you explicitly click Resume agents. Clicking Pause prevents new jobs from being claimed but does not terminate a model request already in progress. When the Mac is sleeping, the last heartbeat becomes stale, although the Cloudflare queue remains intact.

## Status, stop, and diagnostic commands

    node tools/deepseek-agents/cloudflare/mac-client.mjs --status
    node tools/deepseek-agents/cloudflare/mac-client.mjs --pause
    node tools/deepseek-agents/cloudflare/mac-client.mjs --once

The queue can be paused immediately. An already-running model request may finish or reach its timeout, so pause is not a hard mid-request kill switch.

To disable the Mac background process:

    launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.mp3shelf.cloud-coordinator.plist"

Local logs:

    ~/Library/Application Support/MP3ShelfCloudCoordinator/worker.log
    ~/Library/Application Support/MP3ShelfCloudCoordinator/worker-errors.log

If the Mac is offline, queued work stays in D1. If a lease expires, the coordinator retries once and then blocks that job to prevent a spending loop. The next successful milestone requeues the same role; failures do not silently merge code.

## Verification

Local non-paid contract tests are provided:

    node --test tools/deepseek-agents/cloudflare/worker.test.mjs
    node --test tools/deepseek-agents/runner.test.mjs tools/deepseek-agents/publish.test.mjs

These test worker business logic with a deterministic fake D1 engine; they do **not** test actual Cloudflare deployment, a real DeepSeek API call, or actual iOS builds. A real Xcode/iPhone PASS cannot be inferred from these tests.

## Existing GitHub publishing

The Mac-specific GitHub draft publisher is now staged as a protected LaunchDaemon. It is **not automatically installed** when the Cloudflare coordinator installs, because it needs a separate GitHub fine-grained token.

On your Mac, after the normal agent/Cloudflare installer has been configured and verified:

    sudo bash tools/deepseek-agents/mac/install-mac-publisher.sh

Use a fine-grained PAT limited to `jonnyt123/mp3-shelf` with repository Contents read/write and Pull requests read/write. This token is stored **root-only** in `/Library/Application Support/MP3ShelfPublisher/publisher.token` (0600); DeepSeek/OpenCode never receives it. The root-owned broker polls for SHA-bound local approvals and pushes only matching `agent/mp3-*` branches without force-pushing. It creates draft PRs against the dedicated setup branch, not `main` or the untested native PR #4. A verified local commit may still fail native Xcode QA: **no automatic merge is performed**.

To disable publishing independently of cloud coordination:

    sudo launchctl bootout system /Library/LaunchDaemons/com.mp3shelf.publisher.plist

A separate Mac QA companion can build newly published branches and report a specific unsigned Simulator result, subject to its own local installation and GitHub status-only credential. Passing unsigned Xcode tests is **not** signed physical iPhone acceptance.

Release gate: https://github.com/jonnyt123/mp3-shelf/issues/6

Coordination: https://github.com/jonnyt123/mp3-shelf/issues/22

Code staging PR: https://github.com/jonnyt123/mp3-shelf/pull/23

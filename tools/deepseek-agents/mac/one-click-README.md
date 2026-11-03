# MP3 Shelf — Finder one-click installer

**Purpose:** Give the MP3 Shelf owner one file to double-click without manually writing any Terminal commands.

## Get the installer

The release package is named \`MP3-Shelf-One-Click-Installer.zip\`. Unzip it on your Mac, then **double-click \`Install MP3 Shelf.command\`** in Finder. The command opens Terminal automatically, shows a confirmation dialog, and runs the safe install workflow. Terminal is used solely for installation progress, authenticated Cloudflare sign-in, hidden credential prompts, and macOS administrator approval; you do not need to type any shell commands.

This is a Finder-launchable **.command installer**, not an Apple-signed, notarized .app. On recent macOS versions you may need to choose **System Settings > Privacy & Security > Open Anyway** after attempting to open it once. Do not disable Gatekeeper globally.

The command checks the trusted \`jonnyt123/mp3-shelf\` GitHub origin and \`agent/mp3-deepseek-low-cost-worker\` branch, clones to \`~/MP3ShelfAgents\` if missing, or fast-forwards an existing clean clone. It deliberately refuses to overwrite modified files, existing non-Git directories, unexpected remotes, or another branch. It invokes the already-tested \`mac/setup-all.sh\` rather than reimplementing credential storage or the Cloudflare connection.

On success, the installer offers to copy the **local** coordinator token to the clipboard and open the dashboard. The token is never displayed in Terminal or committed to GitHub.

## Run exactly one agent after checking your DeepSeek balance

The ZIP now also contains **Start First Agent.command**. Only use it AFTER the installer has completed on your Mac. Double-click from Finder — no Terminal commands to type.

The starter reads your DeepSeek Console balance from your locally protected key using the **read-only** balance endpoint. It refuses to start if available credit is below 0.25 in the account currency, if the local daily budget is exhausted, if any job is already leased, or if the first Playback cycle has previously been attempted. Its approval dialog provides **Run One Agent** and **One + Four After QA** choices. The latter authorizes up to four additional paid sessions, one per remaining initial-cycle role, but **only after** the first locally validated commit is automatically published as a draft GitHub PR and the independent Mac simulator build/Swift regression suite reports success for the **exact same SHA**. The default 0.50-per-day spending ledger is only a soft observed limit, not a guaranteed maximum bill.

After your approval, it pauses the cloud queue, stops the existing background coordinator in your user session, temporarily permits just the first Playback job lease, immediately pauses Cloudflare once leased, then runs one coding session. A cleanup handler restores the paused state and your normal login background service. If you chose **One + Four After QA**, the background Mac coordinator waits for **root-owned proof receipts** from the draft-PR publisher and independent GitHub QA-status reporter. Only after both match the first commit SHA will it unlock the four remaining initial cycles sequentially. Any failed attempt, mismatched proof, manual pause, or unexpected lease halts further work. It automatically pauses before any second-round (cycle 1) job can run. A hard Mac crash before the initial pause command reaches Cloudflare is a small unavoidable window without server-side one-shot leasing; the normal background coordinator is unloaded during that operation.

On success, a verified local commit is recorded and may be published as a draft PR by the separate GitHub broker. The first cycle is not automatically merged or treated as a signed iPhone test.

### Requirements and safeguards

- macOS, an Internet connection, and **full Xcode** installed/selected. The command can initiate the macOS Command Line Tools installer when Git is missing.
- Homebrew, Node 22+ and OpenCode V2 are installed/checked by the existing guided setup. You may need to approve Homebrew's first-time installation.
- Cloudflare OAuth sign-in, a DeepSeek Console API key, and two narrow GitHub PATs may still require your input on first use. macOS may ask for the administrator password to install protected draft PR and QA status services.
- Only the **existing Cloudflare Free** coordinator and D1 database are used. No Oracle card, GitHub Actions, new Cloudflare database, or OpenAI API calls.
- The Mac installer **pauses** the queue before launching the worker, does not make DeepSeek model requests, and does not automatically merge or release the app. After checking your DeepSeek account's balance, you may explicitly resume the agents from the dashboard.
- The existing physical-iPhone acceptance gate remains in force. A successful installer is not evidence of a real coding cycle or successful hardware build.

### Rebuild this ZIP from the committed source

\`\`\`bash
python3 tools/deepseek-agents/mac/package-one-click.py
\`\`\`

The packager creates \`dist/MP3-Shelf-One-Click-Installer.zip\` with an executable mode preserved for the \`.command\` member. It uses only Python's standard library and does not run the installer. The package is not signed or notarized; that would require a macOS signing environment and Apple Developer ID.

### Tests

\`\`\`bash
node --test tools/deepseek-agents/mac/one-click-installer.test.mjs
\`\`\`

This validates the bash syntax and safety guardrails but cannot simulate macOS Finder, Gatekeeper, launchd, Xcode, live DeepSeek, or Apple account sign-ins on another OS.

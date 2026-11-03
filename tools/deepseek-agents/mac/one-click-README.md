# MP3 Shelf — Finder one-click installer

**Purpose:** Give the MP3 Shelf owner one file to double-click without manually writing any Terminal commands.

## Get the installer

The release package is named \`MP3-Shelf-One-Click-Installer.zip\`. Unzip it on your Mac, then **double-click \`Install MP3 Shelf.command\`** in Finder. The command opens Terminal automatically, shows a confirmation dialog, and runs the safe install workflow. Terminal is used solely for installation progress, authenticated Cloudflare sign-in, hidden credential prompts, and macOS administrator approval; you do not need to type any shell commands.

This is a Finder-launchable **.command installer**, not an Apple-signed, notarized .app. On recent macOS versions you may need to choose **System Settings > Privacy & Security > Open Anyway** after attempting to open it once. Do not disable Gatekeeper globally.

The command checks the trusted \`jonnyt123/mp3-shelf\` GitHub origin and \`agent/mp3-deepseek-low-cost-worker\` branch, clones to \`~/MP3ShelfAgents\` if missing, or fast-forwards an existing clean clone. It deliberately refuses to overwrite modified files, existing non-Git directories, unexpected remotes, or another branch. It invokes the already-tested \`mac/setup-all.sh\` rather than reimplementing credential storage or the Cloudflare connection.

On success, the installer offers to copy the **local** coordinator token to the clipboard and open the dashboard. The token is never displayed in Terminal or committed to GitHub.

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

# MP3 Shelf — DeepSeek low-cost development workers

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

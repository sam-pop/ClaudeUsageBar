# ClaudeUsageBar

A lightweight macOS menu bar app that shows your Claude API usage limits at a glance. Zero dependencies — just Apple frameworks.

[![CI](https://github.com/sam-pop/ClaudeUsageBar/actions/workflows/ci.yml/badge.svg)](https://github.com/sam-pop/ClaudeUsageBar/actions/workflows/ci.yml)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![Zero Dependencies](https://img.shields.io/badge/dependencies-0-green)

## What It Does

ClaudeUsageBar sits in your menu bar showing a usage window and its reset countdown. Click to see full details — both usage windows, color-coded progress bars, live countdowns, and a 24-hour usage trend sparkline.

It reuses the OAuth credentials that Claude Code stores in the macOS Keychain and calls the Anthropic usage API directly — Claude Code doesn't need to be running.

**Multiple accounts.** Track more than one Claude account at once (e.g. personal + work). Each account refreshes independently, so once added they all stay live without switching Claude Code's login. With one account the menu bar is unchanged; with two or more it shows a compact per-account summary like `P 45% · W 82%`, with a full breakdown per account in the popover. See [Multiple accounts](#multiple-accounts).

**Key features:**

- Track one or more Claude accounts, each refreshing independently
- Compact multi-account menu bar (`P 45% · W 82%`) with editable per-account prefixes
- Color-coded (green / yellow / red) by usage level
- Live reset countdowns that tick every second
- Menu-bar display modes — **Auto** (whichever window is higher), **5h**, or **7d**
- Per-account, per-window system notifications at configurable thresholds (default 80% and 90%)
- Proactive token refresh before expiry, with a reactive 401/403 fallback
- Exponential backoff on transient network errors
- Persistent state — instant data on relaunch, no loading spinner

## Install

Requires **macOS 13+**, **Xcode 16+**, **XcodeGen** (`brew install xcodegen`), and **Claude Code** logged in at least once.

```bash
git clone https://github.com/sam-pop/ClaudeUsageBar.git
cd ClaudeUsageBar
make install    # builds + copies to /Applications
```

Or just `make run` to build and launch without installing.

## Usage

1. **Launch the app** — appears in your menu bar
2. **Allow Keychain access** — click **Always Allow** if prompted the first time (see [Troubleshooting](#troubleshooting))
3. **Allow notifications** — for usage threshold alerts
4. Click the menu bar icon for the full breakdown

## Multiple accounts

The first account is picked up automatically from whatever Claude Code is logged into. To add another:

1. In **Claude Code**, log into the second account (e.g. `claude /login`).
2. Open the popover and click **Add current account**.
3. That's it — the app captures the account and, from then on, refreshes it independently. You can switch Claude Code back to your first account; both keep updating.

Each account is identified by its Anthropic account ID (fetched from the OAuth profile endpoint), so the app auto-labels it, **won't add the same account twice**, and — if a token ever needs re-reading — verifies Claude Code is logged into the *right* account before overwriting anything.

In the popover, each account has a **✎** to rename it and set a custom **menu-bar prefix** (the `P` / `W` letters — override with anything, e.g. `Me` or `🏠`), and a **🗑** to remove it. Prefixes are auto-derived from labels and de-duplicated when they'd collide.

**Note on the menu bar with 2+ accounts:** the bar shows each account's percentage but drops the reset countdown to stay compact — open the popover for full countdowns, progress bars, and sparklines per account.

| Target | Description |
|--------|-------------|
| `make build` | Build Release binary |
| `make run` | Build + launch |
| `make install` | Build + copy to `/Applications` |
| `make test` | Run the unit-test suite |
| `make clean` | Remove build artifacts |

## Screenshots

**Menu Bar**

![Menu Bar](screenshots/menubar.png)

**Popover**

<img src="screenshots/popover.png" width="300" alt="Popover">

## How It Works

```
Claude Code Keychain item ──▶ captured per account (Add current account)
(current login)                     │
                                    ▼
              AccountCredentialManager ──▶ one app-owned Keychain item
                                    ▲       "com.sam.ClaudeUsageBar"
              per-account, atomic   │       payload = { accountID: credentials }
              read-modify-write     │       (no-prompt reads, encrypted at rest)
                                    ▼
              AccountsViewModel (coordinator)
                 owns one AccountRuntime per account
                    │            │
   independent OAuth │            │ Anthropic API
   token refresh ────┘            ├─ GET /api/oauth/profile  (identity: uuid/email)
   (per account)                  └─ GET /oauth/usage        ({five_hour, seven_day})
                                    │
                                    ▼
                              MenuBarExtra
                       1 account:  ✦ 42% · 2h 15m   (unchanged)
                       2+ accounts: ● P 45% · ● W 82%
                              [Popover: one section per account + sparklines]
```

**Credential storage.** All accounts' credentials live in a **single** app-owned Keychain item (`com.sam.ClaudeUsageBar`) whose payload is a JSON map keyed by account ID. One Keychain item means one access-control entry (not one per account) and no orphaned items. Writes are done as a verified read-modify-write of a single slot, and a present-but-unreadable item (e.g. after a code-signature change) is never overwritten — so a locked or ACL-broken Keychain can't wipe your other accounts. On upgrade from an older single-account build, the existing credentials are migrated into this map (and the legacy item/plaintext cache deleted) only **after** the new copy is verified to have persisted.

**Token refresh.** Each account's access token is refreshed **proactively** before it expires using that account's own stored refresh token — no Keychain prompt, and no dependence on which account Claude Code is currently logged into. A **reactive** refresh on a 401/403 is the safety net. A per-account circuit breaker only trips on genuine token rejections (400/401/403); network blips, 429s, and 5xx don't count, so a flaky connection never strands an account. Re-reading from Claude Code (for a dead refresh token) is identity-guarded.

**Resilience.** Transient failures (network errors, HTTP 5xx) are retried with exponential backoff (3 attempts, ~1s / 2s / 4s, jittered).

## Smart Features

| Feature | Detail |
|---------|--------|
| **Multiple accounts** | Track 1+ accounts, each refreshing independently; deduped by Anthropic account ID |
| **Per-account, per-window notifications** | Separate alerts per account for the 5-hour and 7-day windows, e.g. "Work: 5-hour window at 82%" |
| **Configurable thresholds** | Defaults to 80% and 90%; override via `defaults` (see below) |
| **Single-item Keychain store** | All accounts in one app-owned Keychain item; verified writes never clobber other accounts |
| **Independent token refresh** | Each account refreshes proactively before expiry; reactive 401/403 fallback; breaker trips only on real rejections |
| **Identity-guarded re-read** | Re-reading a dead login verifies Claude Code is on the right account first |
| **Exponential backoff** | Retries transient errors with jittered backoff; auth errors take the refresh path |
| **24h sparkline** | Per account; samples every 5min, up to 288 points |
| **Namespaced persistence** | Last data + history saved per account in UserDefaults |
| **Graceful errors** | Shows stale data + error banner instead of a blank screen |

### Configuring notification thresholds

There's no settings UI for this yet. Set your own thresholds (integers, 1–100) with:

```bash
defaults write com.sam.ClaudeUsageBar notificationThresholds -array 80 90
```

Restart the app for the change to take effect. Invalid entries are ignored, values are clamped to 1–100, sorted, and de-duplicated; an empty or all-invalid list falls back to the default `[80, 90]`.

## Project Structure

```
ClaudeUsageBar/
├── project.yml                    # XcodeGen project spec
├── Makefile                       # Build automation
├── .github/workflows/ci.yml       # Build + test on macOS runners
├── ClaudeUsageBar/
│   ├── ClaudeUsageBarApp.swift    # @main entry point
│   ├── AppInfo.swift              # Shared version / User-Agent helper
│   ├── Models/
│   │   ├── UsageData.swift          # API response + snapshot + history
│   │   ├── Account.swift            # Account identity + AccountsStore (accounts.v1)
│   │   └── AccountPersistence.swift # Per-account snapshot/history (namespaced)
│   ├── Logic/                       # Pure, unit-tested units
│   │   ├── MenuBarSelection.swift   # Which window a single account shows
│   │   ├── MenuBarPresentation.swift# Menu-bar text for 0/1/N accounts
│   │   ├── MultiAccountMenuBar.swift# Prefix dedupe + compact composition
│   │   ├── UsageFormatting.swift    # Countdown / "updated" formatters
│   │   ├── ThresholdTracker.swift   # Per-window threshold crossings + hysteresis
│   │   ├── HistoryBuffer.swift      # 5-min sampling, 288-point cap
│   │   ├── RefreshCircuitBreaker.swift # Trip-on-rejection + timed re-arm
│   │   ├── OAuthRefreshOutcome.swift   # Classifies refresh failures
│   │   └── RetryPolicy.swift        # Exponential-backoff calculator
│   ├── Services/
│   │   ├── KeychainService.swift    # Claude Code capture + OAuth refresh + migration read
│   │   ├── CredentialStore.swift    # (legacy single-item store, migration source)
│   │   ├── AccountCredentialStore.swift # Single-item multi-account Keychain map + manager
│   │   ├── AccountMigration.swift   # One-time single→multi migration (idempotent, safe)
│   │   ├── ProfileService.swift     # GET /api/oauth/profile (account identity)
│   │   └── UsageAPIService.swift    # Usage API client + error classification
│   ├── ViewModels/
│   │   ├── AccountsViewModel.swift  # Coordinator: accounts, timer, notifications, ops
│   │   └── AccountRuntime.swift     # One account's refresh loop + state
│   └── Views/
│       ├── MenuBarLabel.swift       # 1-account (unchanged) / N-account label
│       ├── MenuBarImage.swift       # AppKit drawing (badge + colored-dot summary)
│       ├── ProgressBarView.swift    # Animated gradient bar with glow
│       ├── SparklineView.swift      # 24h trend graph with time axis
│       ├── UsageSectionView.swift   # Card with bar + live countdown
│       ├── UsageColor.swift         # Level → SwiftUI color
│       ├── AccountRowView.swift     # One account's popover block (+ edit/remove)
│       └── UsagePopoverView.swift   # Full popover layout
└── ClaudeUsageBarTests/             # Swift Testing unit tests
```

## Testing

The test target is an unhosted `bundle.unit-test` that compiles the app sources directly and exercises the pure logic units and model/service helpers with [Swift Testing](https://developer.apple.com/documentation/testing):

```bash
make test
```

CI runs the same build + test on every push and pull request (see the badge above).

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "No OAuth token found" | Log into Claude Code once (`claude` → login flow) |
| An account shows an error / token expired | Make sure Claude Code is logged into **that** account, then click **Re-read from Claude Code** in its popover section (the re-read is identity-guarded and refuses a mismatched login) |
| "Already tracked" when adding | That account is already added — switch Claude Code's login to the *other* account first, then **Add current account** |
| Keychain prompt / an account needs re-adding after rebuilding from source | With ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`), the app-owned Keychain item is bound to the previous build's code signature, so a rebuilt binary may not be able to read it. Re-capture the affected account via **Add current account** / **Re-read from Claude Code**. |
| Repeated prompts while iterating locally | Sign with a stable, free **"Apple Development"** identity instead of ad-hoc signing so the item's ACL stays valid across rebuilds. |
| No notifications | Check System Settings → Notifications → ClaudeUsageBar; the popover also shows a "Notifications off" shortcut when disabled |

## License

MIT

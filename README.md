# ClaudeUsageBar

A lightweight macOS menu bar app that shows your Claude API usage limits at a glance. Zero dependencies — just Apple frameworks.

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![Zero Dependencies](https://img.shields.io/badge/dependencies-0-green)

## What It Does

ClaudeUsageBar sits in your menu bar showing your 5-hour window usage and reset countdown. Click to see full details — both usage windows, color-coded progress bars, live countdowns, and a trend sparkline.

It reads the OAuth token from macOS Keychain (shared with Claude Code) and calls the Anthropic usage API directly — Claude Code doesn't need to be running.

**Key features:**

- Color-coded sparkle icon (green / yellow / red) based on usage level
- Live reset countdowns that tick every second
- Adaptive refresh rate — faster polling when usage is high
- System notifications at 80% and 90% thresholds
- Persistent state — instant data on relaunch, no loading spinner
- Auto-retry on network errors and token refresh on auth failures

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
2. **Allow Keychain access** — click **Always Allow** when prompted
3. **Allow notifications** — for usage threshold alerts
4. Click the menu bar icon for the full breakdown

| Target | Description |
|--------|-------------|
| `make build` | Build Release binary |
| `make run` | Build + launch |
| `make install` | Build + copy to `/Applications` |
| `make clean` | Remove build artifacts |

## Screenshots

**Menu Bar**

![Menu Bar](screenshots/menubar.png)

**Popover**

<img src="screenshots/popover.png" width="300" alt="Popover">

## How It Works

```
Keychain ──▶ KeychainService ──▶ Token Cache (5min TTL)
                                        │
                                        ▼
Anthropic API ◀──── UsageAPIService (auto-retry) ────▶ UsageViewModel
  GET /oauth/usage    │                                  │ adaptive timer
  {five_hour,         │                                  │ notifications
   seven_day}         │                                  │ persistence
                      │                                  ▼
                      │                            MenuBarExtra
                      │                            ✦ 42% · 2h 15m
                      └────────────────────────── [Popover + sparkline]
```

## Smart Features

| Feature | Detail |
|---------|--------|
| **Adaptive refresh** | 30s when usage ≥ 75%, 60s normal, 120s when < 25% |
| **Notifications** | System alerts at 80% and 90% usage |
| **Token caching** | 5-minute TTL to reduce Keychain reads |
| **Auto-retry** | Retries transient errors; refreshes token on 401/403 |
| **Persistence** | Last known data saved to UserDefaults |
| **Graceful errors** | Shows stale data + error banner instead of blank screen |

## Project Structure

```
ClaudeUsageBar/
├── project.yml                    # XcodeGen project spec
├── Makefile                       # Build automation
└── ClaudeUsageBar/
    ├── ClaudeUsageBarApp.swift    # @main entry point
    ├── Models/
    │   └── UsageData.swift        # API response + snapshot + history
    ├── Services/
    │   ├── KeychainService.swift  # Keychain token extraction
    │   └── UsageAPIService.swift  # API client + retry logic
    ├── ViewModels/
    │   └── UsageViewModel.swift   # State, timers, notifications
    └── Views/
        ├── MenuBarLabel.swift     # Color-coded ✦ + percentage + countdown
        ├── ProgressBarView.swift  # Animated gradient bar with glow
        ├── SparklineView.swift    # Mini trend graph
        ├── UsageSectionView.swift # Card with bar + live countdown
        └── UsagePopoverView.swift # Full popover layout
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "No OAuth token found" | Log into Claude Code once (`claude` → login flow) |
| HTTP 403 | Re-login: `claude /login` for fresh token with correct scopes |
| Keychain denied | Open Keychain Access, find "Claude Code-credentials", allow ClaudeUsageBar |
| No notifications | Check System Settings → Notifications → ClaudeUsageBar |

## License

MIT

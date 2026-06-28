# ClaudeHop

**Switch between multiple Claude Code accounts instantly from your macOS menu bar.**

ClaudeHop is a lightweight, native macOS app built entirely in Swift. No Electron, no Python runtime — just a single binary that lives quietly in your menu bar and lets you hop between Claude Code accounts in one click.

---

## Why ClaudeHop?

If you use Claude Code with multiple accounts (personal, work, different subscriptions), you know the pain: `claude auth logout`, wait, `claude auth login`, browser opens, wait again. Every time.

ClaudeHop eliminates that. It stores each account's credentials securely in macOS Keychain and swaps them instantly — Claude CLI never notices, it just sees fresh credentials.

---

## Features

- **One-click account switching** — no logout, no browser, no waiting
- **Live usage display** — see 5h and 7-day usage for every account at a glance
- **Auto-switch** — automatically hop to the next account when one hits its usage limit
- **Native macOS** — built in Swift with AppKit, not a web app wrapped in Electron
- **Lightweight** — ~40 MB RAM, no background services, no network access except the official Anthropic usage API
- **Secure** — credentials stored exclusively in macOS Keychain, never written to disk in plaintext

---

## Requirements

- macOS 13 Ventura or later
- [Claude Code CLI](https://claude.ai/code) installed (`npm install -g @anthropic-ai/claude-code`)
- At least one Claude account already logged in via `claude auth login`

---

## Install

```bash
git clone https://github.com/your-username/claudehop
cd claudehop
bash install.sh
cp -r "dist/ClaudeHop.app" /Applications/
open "/Applications/ClaudeHop.app"
```

The app icon appears in your menu bar. That's it.

### First launch

On first launch, ClaudeHop auto-imports your currently logged-in Claude account. If macOS shows a Keychain permission dialog, click **"Always Allow"** — this is a one-time step so the app can read and write your credentials without prompting again.

---

## Usage

### Add a second account

1. Click the ClaudeHop icon in the menu bar
2. Select **"Add Claude account..."**
3. Complete the browser login flow
4. The new account appears in the menu immediately

### Switch accounts

Click any account name in the menu. The switch takes under a second.

### Auto-switch

Enable **Auto-switch → Claude Code** in the menu. When your active account's usage reaches 100%, ClaudeHop automatically switches to the next available account and sends a macOS notification.

---

## How it works

Claude CLI reads its active credentials from a specific macOS Keychain entry. ClaudeHop maintains a separate Keychain entry per account and swaps them atomically when you switch:

```
Switch to account B:
  1. Read active token (A) from Keychain → backup to "claudehop:A@email.com"
  2. Read saved token (B) from "claudehop:B@email.com"
  3. Write token B into the Claude CLI Keychain slot
  4. Update ~/.claude.json session state
```

Claude CLI sees valid credentials and works normally. No patching, no proxying, no API keys stored in config files.

---

## Build from source

Requires Swift 5.9+ (comes with Xcode or install via `xcode-select --install`).

```bash
# Development
swift run

# Release build + .app bundle
bash install.sh

# Open in Xcode
open Package.swift
```

---

## Privacy

ClaudeHop makes exactly two types of network requests:

1. `api.anthropic.com/oauth/usage` — to display your usage stats (same endpoint Claude CLI uses)
2. Nothing else. No analytics, no crash reporting, no telemetry.

All credentials stay in your local macOS Keychain.

---

## Contributing

Issues and PRs are welcome. The codebase is small — around 700 lines of Swift across 10 files.

```
Sources/ClaudeSwitcher/
├── MenuBar/        ← NSStatusItem, menu, app lifecycle
├── Core/           ← Claude CLI subprocess logic
├── Keychain/       ← Security.framework wrapper
├── Config/         ← JSON persistence (~/.config/claudehop/)
├── Usage/          ← Anthropic usage API client
├── AutoSwitch/     ← Auto-switch decision logic
└── Models/         ← AccountInfo, UsageState
```

---

## License

MIT — free to use, modify, and distribute.

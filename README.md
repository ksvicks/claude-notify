# claude-notify

You run several Claude Code sessions at once. This tells you which one is
waiting on you.

A macOS menu bar indicator, driven by Claude Code hooks. Red dot means a
session is blocked on a permission prompt. Green tick means one finished.
Click any row to jump to the terminal running it.

<!-- TODO: add a screenshot or GIF of the menu bar in the red and green states -->

## Install

```
/plugin marketplace add ksvicks/claude-notify
/plugin install claude-notify
```

That registers the hooks. Then build the menu bar app:

```
/claude-notify:setup
```

Requires macOS 13 or later and the Xcode command line tools
(`xcode-select --install`) for `swiftc`.

Open the menu and turn on **Open at Login** so it starts with your machine.

## What the indicator means

One burst mark throughout, so the indicator always reads as the same app.
Solid means a session wants you. Outline means none does.

| Icon | Meaning |
|------|---------|
| solid burst, terracotta, with a count | that many sessions are blocked, waiting on your input |
| solid burst, blue, with a count | that many sessions finished their turn |
| outline burst, full contrast, with a count | that many sessions are working |
| outline burst, faint | nothing active |

Two deliberate choices here:

- **No green anywhere.** macOS already puts a green dot in the menu bar for
  "camera is on". A second green dot beside it reads as a system warning
  rather than as this app.
- **Working is full-contrast, not grey.** A working session is ordinary, but
  it still has to be readable at a glance on a busy menu bar.

Terracotta is Claude's colour, shifted lighter in dark mode and darker in
light mode so it stays legible either way. It evokes the brand; it is not
Anthropic's mark.

Icons are SF Symbols. On a system where a symbol is missing, the indicator
falls back to a plain text glyph rather than disappearing.

Sessions are sorted so whatever needs you most sits at the top. A sound plays
once when a session newly starts waiting.

## Settings

Open the menu and choose **Settings…**, or press `,` while the menu is open.

| Setting | Default | What it does |
|---------|---------|--------------|
| Play sound on attention | on | Master switch for the alert sound |
| Open at login | off | Registers the app as a login item |
| Refresh interval | 1.0 s | How often the state directory is scanned, 0.5 to 10 s |
| Notify on: Blocked | on | Sound when a session becomes blocked |
| Notify on: Finished | on | Sound when a session finishes |
| Clear finished sessions | — | Drops `done`, `idle` and `start` rows from the list |

Changes apply immediately. The refresh timer restarts on the spot, with no
need to relaunch.

## How it works

Three moving parts, no daemon and no IPC between them.

1. **Hooks write.** Five Claude Code hooks — `SessionStart`,
   `UserPromptSubmit`, `Notification`, `Stop`, `SessionEnd` — call a shell
   script. It writes one file per session to `~/.claude/session-state/`.
2. **The app reads.** A Swift menu bar app polls that directory once a second
   and renders what it finds.
3. **That is the entire contract.** A plain text header plus the raw hook JSON.
   Either half can be replaced without touching the other.

Some deliberate choices:

- **The hook script has zero dependencies.** Shell builtins and `/bin/date`
  only. No `jq`, no Python. It captures the payload verbatim and lets the app
  do the parsing, so the thing running on your critical path stays trivial.
- **Writes are atomic.** Write to `.tmp`, then `mv`. The app never sees a
  half-written file.
- **Orphans get reaped.** If a session dies without firing `SessionEnd` — a
  crash, `kill -9`, a closed window — the app notices the dead PID and removes
  the stale file. Otherwise a phantom red dot would sit there forever.
- **Idle is not the same as blocked.** Claude Code's `Notification` hook fires
  both for a real permission prompt and for a 60-second idle nudge. Only the
  first earns a red badge.
- **Built from source, on purpose.** The app is signed ad-hoc, which is valid
  only on the machine that built it. That means no Apple Developer account,
  no notarization, and no Gatekeeper warning — at the cost of needing
  `swiftc` present.

## Known limitations

- **macOS only.** It is an AppKit menu bar app.
- **Clicking a row focuses the terminal app, not the exact tab.** Ghostty
  exposes no per-window scripting, so there is no reliable way to target one
  tab. If the terminal is not recognised, it reveals the project folder in
  Finder instead.
- **Recognised terminals:** Ghostty, iTerm2, Terminal.app, WezTerm, kitty,
  VS Code. Others fall back to the Finder behaviour above.
- **One second polling.** Not push. Simple and cheap, but not instant.

## Debugging

Print exactly what the app currently sees, then exit:

```bash
~/Applications/ClaudeSessions.app/Contents/MacOS/ClaudeSessions --dump
```

The menu bar is hard to inspect, so this is the way to check parsing.

Look at the raw state files directly:

```bash
ls -la ~/.claude/session-state/
```

## Upgrading from a manual install

If you previously wired `session-state.sh` into `~/.claude/settings.json` by
hand, remove that `hooks` block after installing the plugin. Otherwise both
copies fire on every event.

## Uninstall

```
/plugin uninstall claude-notify
```

Then remove the app and its state:

```bash
rm -rf ~/Applications/ClaudeSessions.app ~/.claude/session-state
```

## License

MIT

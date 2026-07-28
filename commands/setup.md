---
description: "Build and launch the ClaudeSessions menu bar app"
---

# claude-notify setup

Build the menu bar app and start it. The hooks are already active from the
plugin install; this step only handles the app half.

Do the following, in order:

1. Check that `swiftc` is available:

   ```bash
   command -v swiftc
   ```

   If it is missing, tell the user to run `xcode-select --install` and stop
   here. Do not continue.

2. Build and launch the app:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/menubar/build.sh" --launch
   ```

3. Confirm the app is running:

   ```bash
   pgrep -x ClaudeSessions >/dev/null && echo running || echo "not running"
   ```

4. Report the result to the user in short numbered steps:
   - Whether the build succeeded and where the app was installed.
   - That the indicator is now in the menu bar, on the right side.
   - What the glyphs mean: red `●` means a session is blocked and waiting on
     you, green `✓` means a session finished, grey `◍` means working, hollow
     `○` means nothing active.
   - That they should open the menu and turn on **Open at Login** so the app
     starts automatically.

5. If the build failed, show the actual `swiftc` error output. Do not guess at
   the cause.

Note: the indicator may show `○` until a hook fires. Ask the user to send any
prompt in a Claude Code session to see the state change.

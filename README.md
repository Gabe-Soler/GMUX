<h1 align="center">GMUX</h1>
<p align="center">cmux with a VS Code-style file explorer, and live diffs of the files your AI agents are editing</p>

## What is GMUX?

GMUX is a personal fork of [cmux](https://github.com/manaflow-ai/cmux), the Ghostty-based macOS terminal with vertical tabs and notifications for AI coding agents. It adds a file explorer and agent-aware views, so you can browse a repo and watch Claude or Codex change it without keeping VS Code open.

Everything in cmux still works. GMUX adds the following:

- **Explorer column.** A file tree sits between the workspace tabs and the terminal, styled like VS Code's Explorer. It follows the focused terminal's folder and colours files by git status. Files your `.gitignore` excludes are dimmed. The tree updates live as files change anywhere in it. Toggle it with **⌃⌘E**.
- **Preview tabs.** Single-click a file to preview it in a tab that the next click replaces. Double-click to keep it open.
- **Agent markers.** Files an agent edited in the last 15 minutes get a dot. Folders containing them get one too, so collapsed folders show where the work is.
- **Follow-agent mode.** Click the eye at the top of the Explorer to turn it on. While an agent edits, each file it touches opens beside the agent's terminal without taking focus. The file shows as a live diff against its last commit: removed lines in red, added lines in green, with new lines appearing one at a time. Files edited together open together, up to three stacked panes, then as tabs. **Show File** in a pane's header switches back to the normal editor.
- **`cmux files` CLI.** Agents and scripts can drive the Explorer:

  ```bash
  cmux files state                 # root, selection, follow mode, recent agent edits
  cmux files tree --depth 2        # print the tree
  cmux files reveal src/app.ts     # expand to a file and select it
  cmux files open README.md --pin  # open a file as a pinned tab
  cmux files show | hide | toggle  # show or hide the Explorer column
  cmux files follow on | off       # turn follow-agent mode on or off
  ```

## Run GMUX locally

GMUX is built from source on your own Mac. No Apple developer account is needed: the app is signed locally and is meant for your own use.

### One-time setup

1. Install **Xcode** from the App Store, open it once to accept the license, then install the Metal toolchain:

   ```bash
   xcodebuild -downloadComponent MetalToolchain
   ```

2. Install **Rust**:

   ```bash
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   ```

3. Install **Zig 0.16.0**. Download `zig-aarch64-macos-0.16.0.tar.xz` from [ziglang.org/download](https://ziglang.org/download/) and unpack it to `~/.local/zig/zig-aarch64-macos-0.16.0`.

4. Set up the checkout (submodules, prebuilt GhosttyKit, git hooks):

   ```bash
   cd ~/GMUX
   export PATH="$HOME/.local/zig/zig-aarch64-macos-0.16.0:$HOME/.cargo/bin:$PATH"
   ./scripts/setup.sh
   ```

Go is not needed. It only powers cmux Cloud's VPN, which a locally signed build can't use.

### Build and install

```bash
cd ~/GMUX
./scripts/gmux-install.sh
```

Run it from macOS's Terminal app, not from a GMUX terminal, because installing quits GMUX and would kill the script. It builds GMUX in Release mode, which takes several minutes. It then quits GMUX if it's running, installs it as `/Applications/GMUX.app` and opens it. Run the same command again to update after you change the code or pull from upstream. `--no-open` skips opening the app, and `--skip-build` reinstalls the last build.

The script only ever touches GMUX. It refuses to replace anything at `/Applications/GMUX.app` that isn't GMUX, and never quits or overwrites a regular cmux install.

On first launch macOS may say the app is from an unidentified developer. Right-click **GMUX** in Applications, choose **Open**, then **Open** again. You only need to do this once.

### What the installed app has switched off

The install step names the app GMUX in the menu bar and switches off the parts of cmux that talk to cmux's servers. It does this with cmux's own administrator policies, so they're enforced everywhere and Settings shows them as managed:

| Policy | Effect |
| --- | --- |
| `DisableTelemetry` | No crash reports or anonymous analytics are sent. |
| `DisableAutoUpdate` | GMUX never offers to replace itself with an official cmux release. |
| `DisableCloud` | cmux Cloud machines and the Cloud VPN are hidden. They need cmux's servers. |
| `DisableRemoteControl` | No iOS companion pairing. |

To change the list, edit `POLICIES` in `scripts/gmux-install.sh` and reinstall.

### Good to know

- **GMUX runs alongside cmux.** Its bundle ID is `com.cmuxterm.app.debug.gmux`, so it keeps its own settings and sessions.
- **The app is signed on your Mac.** It isn't notarized by Apple, which is why the first launch shows a warning. Nothing else differs.
- **Sign-in does nothing.** The account menu may still appear, but there is no cmux backend behind a local build.
- **Live diffs compare against the last commit.** A line the agent added and later changed fades out instead of turning red. Edits made through shell commands such as `sed` aren't followed. Only the agent's edit tools are.

### Dev builds

For a debug build while working on GMUX itself:

```bash
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag explorer
open -n ~/Library/Developer/Xcode/DerivedData/cmux-explorer/Build/Products/Debug/"cmux DEV explorer.app"
```

First run the `export` lines in `scripts/gmux-install.sh`. See [CONTRIBUTING.md](CONTRIBUTING.md) for tests and the rest of the contributor workflow.

## Upstream

GMUX tracks [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux). For cmux's own features, docs and keyboard shortcuts, see [cmux.com/docs](https://cmux.com/docs/getting-started). The translated `README.*.md` files describe upstream cmux, not GMUX.

## License

GMUX is a modified version of cmux and keeps its license: [GPL-3.0-or-later](LICENSE), with the server directories listed in [LICENSE](LICENSE) under the [Business Source License 1.1](web/LICENSE). Copyright in the original cmux code belongs to Manaflow, Inc. and its contributors.

# Codex Input Unlock (`codex-input-unlock`)

English | [简体中文](README.md)

An **external runtime input unlocker** for the official Codex Desktop and ChatGPT Desktop applications on Windows and macOS.

When a user has configured a **third-party API provider, relay, or self-hosted gateway**, the official desktop client may still disable the composer and send button if the signed-in official account has exhausted its quota. Codex Input Unlock uses Chrome DevTools Protocol (CDP) to install a dynamic, non-pausing conditional breakpoint that **removes this local frontend input and send gate**.

> [!IMPORTANT]
> **Scope and disclaimer:**
> This project does **not and cannot** bypass, restore, or increase an OpenAI account's official quota. Its only purpose is to remove an unnecessary local frontend gate when you are already using **your own third-party API key and provider**.

---

## Features

- 🛡️ **No package modification:** Does not modify the Store Appx package, macOS `.app` bundle, ASAR archive, or executable files. The official package and its code signature remain untouched.
- 🔒 **Zero configuration tampering:** Never modifies, overwrites, or synchronizes `~/.codex/config.toml` or `auth.json`. You remain in control of your own configuration.
- ⚡ **Non-pausing conditional breakpoint:** Uses a JavaScript comma expression `(quota = false, false)` to update the local variable while the breakpoint condition always evaluates to false, so the page never pauses.
- 🔄 **Automatic recovery after reload:** Watches the renderer lifecycle and reinstalls the breakpoint after a page reload (`Cmd + R` / `Ctrl + R`).
- 🧩 **Adaptive across app updates:** Tolerates bundling variations across new Codex / ChatGPT releases (string literal quotes, variable declarations, multi-candidate quota atoms).

---

## How it works

```text
Controller
  ├─ Windows: PowerShell controller (codex-input-unlock.ps1)
  │    ├─ Identifies official Store package (Codex / ChatGPT Desktop)
  │    └─ Activates client with remote-debugging arguments via COM
  └─ macOS: Shell controller (codex-input-unlock.sh)
       ├─ Identifies /Applications (ChatGPT.app / Codex.app)
       └─ Activates client with remote-debugging arguments via LaunchServices
                         │
                         ▼
CDP supervisor (cdp-supervisor.mjs + quota-gate.cjs)
  ├─ Connects to the client renderer through CDP
  ├─ Locates the quota gate in the frontend JavaScript bundle
  ├─ Installs a conditional breakpoint: (quota = false, false)
  │    └─ Clears the local gate without pausing the renderer
  └─ Reinstalls the injection after a page reload
```

---

## Requirements

- **Operating system:**
  - Windows 10 or Windows 11 (x64 / ARM64)
  - macOS 12+ (Apple Silicon / Intel)
- **Official client:**
  - Windows: Microsoft Store version of Codex Desktop or ChatGPT Desktop
  - macOS: `/Applications/ChatGPT.app` or `/Applications/Codex.app`
- **Runtime dependencies:**
  - Node.js 22+
  - Windows: PowerShell 7+ (`pwsh`)
  - macOS: Bash / Zsh (built into macOS)

---

## Quick start

### Configure your provider first

Before launching Codex Input Unlock, configure and verify your third-party provider in `~/.codex/config.toml`. This project does not create, modify, or validate provider configuration for you.

If you want to retain your official Codex account login while using the third-party provider, set the following option in the corresponding provider configuration:

```toml
requires_openai_auth = true
```

You must also sign in to your account in the desktop client before using the unlocker. The third-party provider, `requires_openai_auth = true`, and the login state must already be configured. Codex Input Unlock only removes the local input and send gate caused by the official quota state; it does not replace provider setup or account login.

---

### macOS Quick Start

#### 1. Install

Clone the repository and run:

```bash
git clone https://github.com/Wtrwx/codex-input-unlock.git
cd codex-input-unlock
chmod +x ./codex-input-unlock.sh
./codex-input-unlock.sh install
```

*Installation copies runtime files to `~/Library/Application Support/OpenAI/CodexInputUnlock`, creates a **Codex Input Unlock.app** application (using the official squircle icon) in `~/Applications`, and installs a symlink to `~/.local/bin/codex-input-unlock`.*

#### 2. Launch

- **Option A (recommended):** Launch **`Codex Input Unlock`** from Spotlight or `~/Applications`.
  - If the client is not running: launches the client with CDP debugging enabled and arms the unlock breakpoint.
  - If the client is already running unlocked: brings the window to the front without erroring.
  - If a normal (non-unlocked) client is running: prompts you to quit it (`Cmd+Q`) first.
- **Option B (command line):**
  ```bash
  codex-input-unlock launch
  # Or force-restart a running client with unlock enabled:
  codex-input-unlock launch --force
  ```

#### 3. Verify

```bash
codex-input-unlock verify
```

`runtimeReady: true` confirms the supervisor is active and the breakpoint is armed.

#### macOS Commands

| Action | Description |
| :--- | :--- |
| `./codex-input-unlock.sh diagnose` | Checks runtime dependencies, app path, and files |
| `./codex-input-unlock.sh launch [--force]` | Starts supervisor and launches client with debugging flags (`--force` restarts running instances) |
| `./codex-input-unlock.sh verify` | Checks supervisor process, CDP connectivity, and breakpoint status |
| `./codex-input-unlock.sh inspect` | Outputs diagnostic JSON with recent logs |
| `./codex-input-unlock.sh uninstall` | Stops supervisor and removes app shortcut and files |

---

### Windows Quick Start

#### 1. Install

In PowerShell 7:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File '.\codex-input-unlock.ps1' -Action Install
```

#### 2. Launch

- **Option A (recommended):** Open Start menu and click **Codex Input Unlock**.
- **Option B (command line):**
  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass `
    -File "$env:LOCALAPPDATA\OpenAI\CodexInputUnlock\codex-input-unlock.ps1" `
    -Action Launch
  ```

#### 3. Verify

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass `
  -File "$env:LOCALAPPDATA\OpenAI\CodexInputUnlock\codex-input-unlock.ps1" `
  -Action Verify
```

---

## Upgrade Adaptation & Resilience

Instead of patching binaries directly, this tool sets dynamic zero-pause CDP breakpoints at runtime, giving it high resilience across app updates:

1. **Quote & Bundler Flexibility:**
   Tolerates single-quotes, double-quotes, and template literals generated by Vite / Rolldown / SWC.
2. **Flexible Assignment Expressions:**
   Matches `let`, `const`, and `var`, and locates the quota predicate variable even if terms in the `||` chain are reordered.
3. **Multi-Candidate Evaluation:**
   Scans all candidate quota atoms and selects the one that directly connects to `submitDisabled`.
4. **Zero-Pause Side-Effect:**
   Uses V8 debugger evaluation side-effects: `(quota = false, false)`. The expression clears the variable, while evaluating to `false` ensures the page is never suspended.

---

## Testing

```bash
# macOS / Linux static smoke tests
bash ./tests/smoke.sh

# Windows static smoke tests
pwsh -NoProfile -ExecutionPolicy Bypass -File '.\tests\smoke.ps1' -SkipPackageCheck
```

---

## License

[MIT](LICENSE)

[LINUX DO](https://linux.do)

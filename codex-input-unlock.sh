#!/usr/bin/env bash
#
# Codex Input Unlock (codex-input-unlock) - macOS controller
#
# Unlocks local composer quota gate for Codex / ChatGPT Desktop via CDP.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT_DEFAULT="${HOME}/Library/Application Support/OpenAI/CodexInputUnlock"
INSTALL_ROOT="${CODEX_INPUT_UNLOCK_INSTALL_ROOT:-$INSTALL_ROOT_DEFAULT}"
STARTUP_TIMEOUT=60
DEBUG_PORT=0
GUI_MODE=0
DRY_RUN=0
NO_SHORTCUT=0
FORCE_RESTART=0

STATE_DIR="${INSTALL_ROOT}/state"
LOG_DIR="${INSTALL_ROOT}/logs"
STATE_PATH="${STATE_DIR}/install-state.json"
SETTINGS_PATH="${STATE_DIR}/settings.json"
RUNTIME_CONTROLLER="${INSTALL_ROOT}/codex-input-unlock.sh"
RUNTIME_SUPERVISOR="${INSTALL_ROOT}/cdp-supervisor.mjs"
RUNTIME_GATE="${INSTALL_ROOT}/quota-gate.cjs"

log_info() {
  echo "[codex-input-unlock] $*"
}

log_error() {
  echo "[codex-input-unlock] ERROR: $*" >&2
}

show_gui_alert() {
  local title="$1"
  local message="$2"
  if [[ "$GUI_MODE" -eq 1 ]] && command -v osascript >/dev/null 2>&1; then
    osascript -e "display alert \"$title\" message \"$message\" as critical" || true
  fi
}

resolve_codex_app() {
  local candidates=(
    "/Applications/ChatGPT.app"
    "/Applications/Codex.app"
    "${HOME}/Applications/ChatGPT.app"
    "${HOME}/Applications/Codex.app"
  )
  for app in "${candidates[@]}"; do
    if [[ -d "$app" ]]; then
      local exec_name
      if [[ -f "${app}/Contents/MacOS/ChatGPT" ]]; then
        exec_name="ChatGPT"
      elif [[ -f "${app}/Contents/MacOS/Codex" ]]; then
        exec_name="Codex"
      else
        exec_name="$(defaults read "${app}/Contents/Info.plist" CFBundleExecutable 2>/dev/null || echo "")"
      fi
      if [[ -n "$exec_name" && -f "${app}/Contents/MacOS/${exec_name}" ]]; then
        echo "$app"
        return 0
      fi
    fi
  done
  return 1
}

get_app_info() {
  local app_path="$1"
  local exec_name
  if [[ -f "${app_path}/Contents/MacOS/ChatGPT" ]]; then
    exec_name="ChatGPT"
  elif [[ -f "${app_path}/Contents/MacOS/Codex" ]]; then
    exec_name="Codex"
  else
    exec_name="$(defaults read "${app_path}/Contents/Info.plist" CFBundleExecutable 2>/dev/null || echo "ChatGPT")"
  fi
  local version
  version="$(defaults read "${app_path}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")"
  local bundle_id
  bundle_id="$(defaults read "${app_path}/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "com.openai.chat")"
  local asar_path="${app_path}/Contents/Resources/app.asar"
  local has_asar=false
  [[ -f "$asar_path" ]] && has_asar=true

  node -e '
    const [appPath, execName, version, bundleId, hasAsar] = process.argv.slice(1);
    console.log(JSON.stringify({
      appPath,
      executablePath: `${appPath}/Contents/MacOS/${execName}`,
      executableName: execName,
      version,
      bundleId,
      hasAsar: hasAsar === "true"
    }));
  ' "$app_path" "$exec_name" "$version" "$bundle_id" "$has_asar"
}

get_running_processes() {
  node -e '
    const { execSync } = require("child_process");
    let output = "";
    try {
      output = execSync("ps -ww -eo pid,command", { encoding: "utf8" });
    } catch {
      console.log("[]");
      process.exit(0);
    }
    const lines = output.split("\n");
    const matches = [];
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const spaceIdx = trimmed.indexOf(" ");
      if (spaceIdx === -1) continue;
      const pid = parseInt(trimmed.slice(0, spaceIdx), 10);
      const cmd = trimmed.slice(spaceIdx + 1).trim();
      const isMainApp = (
        (cmd.startsWith("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT") ||
         cmd.startsWith("/Applications/Codex.app/Contents/MacOS/Codex") ||
         cmd.startsWith(`${process.env.HOME}/Applications/ChatGPT.app/Contents/MacOS/ChatGPT`) ||
         cmd.startsWith(`${process.env.HOME}/Applications/Codex.app/Contents/MacOS/Codex`)) &&
        !cmd.includes("--type=")
      );
      if (isMainApp && !cmd.includes("codex-input-unlock")) {
        const hasDebugPort = cmd.includes("--remote-debugging-port=");
        matches.push({ pid, command: cmd, hasDebugPort });
      }
    }
    console.log(JSON.stringify(matches));
  '
}

get_free_port() {
  node -e '
    const net = require("net");
    const s = net.createServer();
    s.listen(0, "127.0.0.1", () => {
      console.log(s.address().port);
      s.close();
    });
  '
}

action_diagnose() {
  local app_path
  if app_path="$(resolve_codex_app)"; then
    :
  else
    app_path=""
  fi

  local node_bin
  node_bin="$(command -v node || echo "")"
  local node_ver=""
  if [[ -n "$node_bin" ]]; then
    node_ver="$("$node_bin" -v 2>/dev/null || echo "")"
  fi

  local running_json
  running_json="$(get_running_processes)"

  node -e '
    const fs = require("fs");
    const [appPath, nodeBin, nodeVer, runningStr, installRoot, statePath, supervisor, gate] = process.argv.slice(1);
    const running = JSON.parse(runningStr || "[]");
    let appInfo = null;
    if (appPath) {
      try {
        const { execSync } = require("child_process");
        const execName = fs.existsSync(`${appPath}/Contents/MacOS/ChatGPT`) ? "ChatGPT" : "Codex";
        const ver = execSync(`defaults read "${appPath}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo unknown`, { encoding: "utf8" }).trim();
        appInfo = {
          appPath,
          executable: `${appPath}/Contents/MacOS/${execName}`,
          version: ver,
          hasAsar: fs.existsSync(`${appPath}/Contents/Resources/app.asar`)
        };
      } catch {}
    }
    const installed = fs.existsSync(supervisor) && fs.existsSync(gate);
    const state = fs.existsSync(statePath) ? JSON.parse(fs.readFileSync(statePath, "utf8")) : null;
    const diag = {
      platform: "darwin",
      app: appInfo,
      runningProcesses: running,
      node: nodeBin || null,
      nodeVersion: nodeVer || null,
      installed,
      installRoot,
      state,
      configManagedByPatch: false
    };
    console.log(JSON.stringify(diag, null, 2));
  ' "$app_path" "$node_bin" "$node_ver" "$running_json" "$INSTALL_ROOT" "$STATE_PATH" "$RUNTIME_SUPERVISOR" "$RUNTIME_GATE"
}

action_install() {
  local app_path
  if ! app_path="$(resolve_codex_app)"; then
    log_error "No supported OpenAI Codex or ChatGPT Desktop application found in /Applications or ~/Applications."
    exit 1
  fi

  local node_bin
  node_bin="$(command -v node || echo "")"
  if [[ -z "$node_bin" ]]; then
    log_error "Node.js is not installed. Node.js 22+ is required."
    exit 1
  fi
  local node_major
  node_major="$("$node_bin" -p 'process.versions.node.split(".")[0]')"
  if [[ "$node_major" -lt 22 ]]; then
    log_error "Node.js 22 or newer is required; found node $("$node_bin" -v)."
    exit 1
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "Dry run: install prerequisites verified for $app_path."
    return 0
  fi

  mkdir -p "$INSTALL_ROOT" "$STATE_DIR" "$LOG_DIR"
  cp -f "${SCRIPT_DIR}/cdp-supervisor.mjs" "$INSTALL_ROOT/"
  cp -f "${SCRIPT_DIR}/quota-gate.cjs" "$INSTALL_ROOT/"
  cp -f "${BASH_SOURCE[0]}" "${INSTALL_ROOT}/codex-input-unlock.sh"
  chmod +x "${INSTALL_ROOT}/codex-input-unlock.sh"
  for doc in README.md README_EN.md LICENSE; do
    if [[ -f "${SCRIPT_DIR}/${doc}" ]]; then
      cp -f "${SCRIPT_DIR}/${doc}" "$INSTALL_ROOT/"
    fi
  done

  # Write settings.json
  cat <<EOF > "$SETTINGS_PATH"
{
  "startupTimeoutSeconds": ${STARTUP_TIMEOUT},
  "installedAppPath": "${app_path}"
}
EOF

  local shortcut_path=""
  if [[ "$NO_SHORTCUT" -eq 0 ]]; then
    local app_bundle="${HOME}/Applications/Codex Input Unlock.app"
    mkdir -p "${HOME}/Applications"
    rm -rf "$app_bundle"
    mkdir -p "${app_bundle}/Contents/MacOS" "${app_bundle}/Contents/Resources"

    # Prioritize official ChatGPT squircle icon (icon-chatgpt.icns) over app.icns
    if [[ -f "${app_path}/Contents/Resources/icon-chatgpt.icns" ]]; then
      cp -f "${app_path}/Contents/Resources/icon-chatgpt.icns" "${app_bundle}/Contents/Resources/app.icns"
    elif [[ -f "${app_path}/Contents/Resources/app.icns" ]]; then
      cp -f "${app_path}/Contents/Resources/app.icns" "${app_bundle}/Contents/Resources/app.icns"
    fi

    # Create Info.plist
    cat <<EOF > "${app_bundle}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>launcher</string>
    <key>CFBundleIconFile</key>
    <string>app.icns</string>
    <key>CFBundleIdentifier</key>
    <string>com.openai.codex.inputunlock</string>
    <key>CFBundleName</key>
    <string>Codex Input Unlock</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
EOF

    # Create wrapper launcher script
    cat <<EOF > "${app_bundle}/Contents/MacOS/launcher"
#!/usr/bin/env bash
export PATH="/usr/local/bin:/opt/homebrew/bin:\$HOME/.nvm/versions/node/\$(ls -t \$HOME/.nvm/versions/node 2>/dev/null | head -n1)/bin:\$PATH"
exec "${INSTALL_ROOT}/codex-input-unlock.sh" launch --gui
EOF
    chmod +x "${app_bundle}/Contents/MacOS/launcher"
    shortcut_path="$app_bundle"
    log_info "Created application bundle: ${app_bundle}"
  fi

  # Create CLI symlink in ~/.local/bin if directory exists or create it
  mkdir -p "${HOME}/.local/bin"
  ln -sf "${INSTALL_ROOT}/codex-input-unlock.sh" "${HOME}/.local/bin/codex-input-unlock"

  # Write install-state.json
  node -e '
    const fs = require("fs");
    const [statePath, installRoot, appPath, shortcutPath] = process.argv.slice(1);
    const state = {
      schemaVersion: 4,
      platform: "darwin",
      installedAt: new Date().toISOString(),
      installRoot,
      appPath,
      shortcutPath: shortcutPath || null,
      configManagedByPatch: false,
      supervisorPid: null,
      appPid: null,
      debugPort: null,
      lastStatusPath: null,
      lastLaunchAt: null
    };
    fs.writeFileSync(statePath, JSON.stringify(state, null, 2) + "\n", "utf8");
  ' "$STATE_PATH" "$INSTALL_ROOT" "$app_path" "$shortcut_path"

  log_info "Installed successfully to ${INSTALL_ROOT}"
  if [[ -n "$shortcut_path" ]]; then
    log_info "You can launch Codex Input Unlock from Spotlight or ${shortcut_path}"
  fi
}

action_launch() {
  local supervisor_file="${RUNTIME_SUPERVISOR}"
  local gate_file="${RUNTIME_GATE}"

  if [[ ! -f "$supervisor_file" || ! -f "$gate_file" ]]; then
    # Fallback to source directory if not yet installed
    if [[ -f "${SCRIPT_DIR}/cdp-supervisor.mjs" && -f "${SCRIPT_DIR}/quota-gate.cjs" ]]; then
      supervisor_file="${SCRIPT_DIR}/cdp-supervisor.mjs"
      gate_file="${SCRIPT_DIR}/quota-gate.cjs"
      mkdir -p "$STATE_DIR" "$LOG_DIR"
    else
      local msg="Codex Input Unlock is not installed. Run install first."
      show_gui_alert "Launch Error" "$msg"
      log_error "$msg"
      exit 1
    fi
  fi

  local app_path
  if ! app_path="$(resolve_codex_app)"; then
    local msg="No supported OpenAI Codex or ChatGPT Desktop application found."
    show_gui_alert "Launch Error" "$msg"
    log_error "$msg"
    exit 1
  fi

  # Check if app is already running
  local running_json
  running_json="$(get_running_processes)"
  local running_count
  running_count="$(node -e 'console.log(JSON.parse(process.argv[1]).length)' "$running_json")"
  if [[ "$running_count" -gt 0 ]]; then
    # Check if existing instance already has debug port active
    local has_debug
    has_debug="$(node -e 'console.log(JSON.parse(process.argv[1]).every(p => p.hasDebugPort))' "$running_json")"
    if [[ "$has_debug" == "true" && "$FORCE_RESTART" -eq 0 ]]; then
      log_info "ChatGPT is already running with Codex Input Unlock active. Bringing window to front..."
      osascript -e 'tell application "ChatGPT" to activate' 2>/dev/null || open -a "$app_path"
      exit 0
    fi

    if [[ "$FORCE_RESTART" -eq 1 ]]; then
      log_info "Force restart requested. Terminating running instance..."
      node -e 'JSON.parse(process.argv[1]).forEach(p => { try { process.kill(p.pid, "SIGTERM"); } catch {} });' "$running_json"
      sleep 1.5
    else
      local pids
      pids="$(node -e 'console.log(JSON.parse(process.argv[1]).map(p => `PID ${p.pid}`).join(", "))' "$running_json")"
      local error_msg="ChatGPT is already running (PID: ${pids}). Please quit ChatGPT (Cmd+Q) first, or pass --force to restart it."
      show_gui_alert "ChatGPT Already Running" "$error_msg"
      log_error "$error_msg"
      exit 1
    fi
  fi

  local port="$DEBUG_PORT"
  if [[ "$port" -le 0 ]]; then
    port="$(get_free_port)"
  fi
  if [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
    log_error "Invalid debug port: $port"
    exit 1
  fi

  local stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  local status_path="${STATE_DIR}/runtime-status-${stamp}.json"
  local stdout_path="${LOG_DIR}/supervisor-${stamp}.stdout.log"
  local stderr_path="${LOG_DIR}/supervisor-${stamp}.stderr.log"

  log_info "Starting CDP supervisor on port ${port}..."
  node "$supervisor_file" \
    --port "$port" \
    --gate "$gate_file" \
    --status "$status_path" \
    --startup-timeout "$STARTUP_TIMEOUT" \
    > "$stdout_path" 2> "$stderr_path" &
  local supervisor_pid=$!

  # Launch ChatGPT via open -a with debugging flags
  log_info "Launching ${app_path} with remote debugging enabled..."
  open -a "$app_path" --args \
    --remote-debugging-address=127.0.0.1 \
    --remote-debugging-port="$port" \
    --remote-allow-origins="http://127.0.0.1:${port}"

  # Wait for supervisor to reach 'ready' status
  local deadline=$((SECONDS + STARTUP_TIMEOUT))
  local ready=0
  while [[ $SECONDS -lt $deadline ]]; do
    if [[ -f "$status_path" ]]; then
      local state
      state="$(node -e 'try { console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).state || ""); } catch { console.log(""); }' "$status_path")"
      if [[ "$state" == "ready" ]]; then
        ready=1
        break
      elif [[ "$state" == "failed" ]]; then
        local err
        err="$(node -e 'try { console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).error || "unknown"); } catch { console.log("unknown"); }' "$status_path")"
        kill -9 "$supervisor_pid" 2>/dev/null || true
        show_gui_alert "Supervisor Failed" "$err"
        log_error "Supervisor failed: $err"
        exit 1
      fi
    fi

    if ! kill -0 "$supervisor_pid" 2>/dev/null; then
      local err_tail
      err_tail="$(tail -n 20 "$stderr_path" 2>/dev/null || echo "Unknown error")"
      show_gui_alert "Supervisor Crashed" "$err_tail"
      log_error "Supervisor exited prematurely. See $stderr_path"
      exit 1
    fi
    sleep 0.25
  done

  if [[ "$ready" -ne 1 ]]; then
    kill -9 "$supervisor_pid" 2>/dev/null || true
    local timeout_msg="Codex Input Unlock did not become ready within ${STARTUP_TIMEOUT} seconds."
    show_gui_alert "Launch Timeout" "$timeout_msg"
    log_error "$timeout_msg"
    exit 1
  fi

  # Record state
  node -e '
    const fs = require("fs");
    const [statePath, supervisorPid, port, statusPath] = process.argv.slice(1);
    let state = {};
    if (fs.existsSync(statePath)) {
      try { state = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
    }
    state.configManagedByPatch = false;
    state.supervisorPid = parseInt(supervisorPid, 10);
    state.debugPort = parseInt(port, 10);
    state.lastStatusPath = statusPath;
    state.lastLaunchAt = new Date().toISOString();
    fs.writeFileSync(statePath, JSON.stringify(state, null, 2) + "\n", "utf8");
  ' "$STATE_PATH" "$supervisor_pid" "$port" "$status_path"

  log_info "Codex Input Unlock is READY (Supervisor PID: ${supervisor_pid}, Port: ${port}). Composer quota gate is unlocked."
}

action_verify() {
  node -e '
    const fs = require("fs");
    const http = require("http");
    const { execSync } = require("child_process");
    const [statePath, installRoot, supervisor, gate] = process.argv.slice(1);

    let state = null;
    if (fs.existsSync(statePath)) {
      try { state = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
    }
    const lastStatusPath = state?.lastStatusPath;
    let runtime = null;
    if (lastStatusPath && fs.existsSync(lastStatusPath)) {
      try { runtime = JSON.parse(fs.readFileSync(lastStatusPath, "utf8")); } catch {}
    }

    let supervisorAlive = false;
    if (state?.supervisorPid) {
      try {
        process.kill(state.supervisorPid, 0);
        supervisorAlive = true;
      } catch {
        supervisorAlive = false;
      }
    }

    const debugPort = state?.debugPort;
    function checkCdp(port, callback) {
      if (!port) return callback(false, false);
      const req = http.get(`http://127.0.0.1:${port}/json`, { timeout: 2000 }, (res) => {
        let body = "";
        res.on("data", chunk => { body += chunk; });
        res.on("end", () => {
          try {
            const list = JSON.parse(body);
            const hasTarget = Array.isArray(list) && list.some(t => t.type === "page");
            callback(true, hasTarget);
          } catch {
            callback(true, false);
          }
        });
      });
      req.on("error", () => callback(false, false));
      req.on("timeout", () => { req.destroy(); callback(false, false); });
    }

    checkCdp(debugPort, (cdpListening, cdpResponding) => {
      let runtimeFresh = false;
      if (runtime?.updatedAt) {
        const ageSec = (Date.now() - new Date(runtime.updatedAt).getTime()) / 1000;
        runtimeFresh = ageSec < 30;
      }
      const runtimeReady = Boolean(
        runtime &&
        runtime.state === "ready" &&
        supervisorAlive &&
        cdpListening &&
        cdpResponding
      );

      const result = {
        installed: fs.existsSync(supervisor) && fs.existsSync(gate),
        runtime,
        supervisorAlive,
        cdpListening,
        cdpResponding,
        runtimeFresh,
        runtimeReady,
        configManagedByPatch: false,
        note: "Runtime readiness requires a cold launch through the Codex Input Unlock application or script."
      };
      console.log(JSON.stringify(result, null, 2));
    });
  ' "$STATE_PATH" "$INSTALL_ROOT" "$RUNTIME_SUPERVISOR" "$RUNTIME_GATE"
}

action_inspect() {
  node -e '
    const fs = require("fs");
    const path = require("path");
    const [statePath, logDir] = process.argv.slice(1);

    let state = null;
    if (fs.existsSync(statePath)) {
      try { state = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}
    }
    let runtime = null;
    if (state?.lastStatusPath && fs.existsSync(state.lastStatusPath)) {
      try { runtime = JSON.parse(fs.readFileSync(state.lastStatusPath, "utf8")); } catch {}
    }

    let logs = [];
    if (fs.existsSync(logDir)) {
      const files = fs.readdirSync(logDir)
        .map(f => {
          const fp = path.join(logDir, f);
          const stat = fs.statSync(fp);
          return { name: f, path: fp, mtime: stat.mtimeMs, size: stat.size };
        })
        .sort((a, b) => b.mtime - a.mtime)
        .slice(0, 4);

      logs = files.map(f => {
        const lines = fs.readFileSync(f.path, "utf8").split("\n").filter(Boolean);
        return {
          path: f.path,
          size: f.size,
          lastWriteTime: new Date(f.mtime).toISOString(),
          tail: lines.slice(-40)
        };
      });
    }

    const report = {
      capturedAt: new Date().toISOString(),
      state,
      runtime,
      configManagedByPatch: false,
      logs
    };
    console.log(JSON.stringify(report, null, 2));
  ' "$STATE_PATH" "$LOG_DIR"
}

action_uninstall() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "Dry run: uninstall would remove ${INSTALL_ROOT} and shortcuts."
    return 0
  fi

  if [[ -f "$STATE_PATH" ]]; then
    local pid
    pid="$(node -e 'try { console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).supervisorPid || ""); } catch { console.log(""); }' "$STATE_PATH")"
    if [[ -n "$pid" ]]; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi

  rm -rf "${HOME}/Applications/Codex Input Unlock.app"
  rm -f "${HOME}/.local/bin/codex-input-unlock"
  rm -rf "$INSTALL_ROOT"
  log_info "Codex Input Unlock uninstalled successfully."
}

# --- Main CLI Router ---
main() {
  local action=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -Action|--action)
        action="$2"
        shift 2
        ;;
      -InstallRoot|--install-root)
        INSTALL_ROOT="$2"
        STATE_DIR="${INSTALL_ROOT}/state"
        LOG_DIR="${INSTALL_ROOT}/logs"
        STATE_PATH="${STATE_DIR}/install-state.json"
        SETTINGS_PATH="${STATE_DIR}/settings.json"
        RUNTIME_CONTROLLER="${INSTALL_ROOT}/codex-input-unlock.sh"
        RUNTIME_SUPERVISOR="${INSTALL_ROOT}/cdp-supervisor.mjs"
        RUNTIME_GATE="${INSTALL_ROOT}/quota-gate.cjs"
        shift 2
        ;;
      -DebugPort|--debug-port)
        DEBUG_PORT="$2"
        shift 2
        ;;
      -StartupTimeoutSeconds|--startup-timeout)
        STARTUP_TIMEOUT="$2"
        shift 2
        ;;
      -NoShortcut|--no-shortcut)
        NO_SHORTCUT=1
        shift
        ;;
      -DryRun|--dry-run)
        DRY_RUN=1
        shift
        ;;
      --gui)
        GUI_MODE=1
        shift
        ;;
      -Force|--force|-f)
        FORCE_RESTART=1
        shift
        ;;
      Diagnose|diagnose|Install|install|Launch|launch|Verify|verify|Inspect|inspect|Uninstall|uninstall)
        action="$1"
        shift
        ;;
      -h|--help|help)
        echo "Usage: ./codex-input-unlock.sh [diagnose|install|launch|verify|inspect|uninstall]"
        exit 0
        ;;
      *)
        log_error "Unknown parameter or action: $1"
        exit 1
        ;;
    esac
  done

  if [[ -z "$action" ]]; then
    action="diagnose"
  fi

  local action_lower
  action_lower="$(echo "$action" | tr '[:upper:]' '[:lower:]')"
  case "$action_lower" in
    diagnose)   action_diagnose ;;
    install)    action_install ;;
    launch)     action_launch ;;
    verify)     action_verify ;;
    inspect)    action_inspect ;;
    uninstall)  action_uninstall ;;
    *)
      log_error "Unsupported action: $action"
      exit 1
      ;;
  esac
}

main "$@"

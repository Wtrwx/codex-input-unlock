#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SUPERVISOR="${REPO_DIR}/cdp-supervisor.mjs"
GATE="${REPO_DIR}/quota-gate.cjs"
CONTROLLER_SH="${REPO_DIR}/codex-input-unlock.sh"
CONTROLLER_PS1="${REPO_DIR}/codex-input-unlock.ps1"

SKIP_APP_CHECK=0
BUNDLE_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-app-check|-SkipPackageCheck)
      SKIP_APP_CHECK=1
      shift
      ;;
    --bundle-path|-BundlePath)
      BUNDLE_PATH="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

echo "[smoke] Checking supervisor and gate syntax..."
node --check "$SUPERVISOR"
node --check "$GATE"
bash -n "$CONTROLLER_SH"

echo "[smoke] Testing quota-gate.cjs API probe..."
node -e '
  const gate = require(process.argv[1]);
  if (typeof gate.locate !== "function" || typeof gate.condition !== "function") {
    throw new Error("quota gate API is incomplete");
  }
  const cond = gate.condition({ mode: "codex-local-quota", quotaVariable: "quota" });
  if (cond !== "(quota=false,false)") {
    throw new Error(`unexpected condition: ${cond}`);
  }
' "$GATE"

echo "[smoke] Checking controller config-integrity..."
controller_text="$(cat "$CONTROLLER_SH")"
if echo "$controller_text" | grep -qiE 'Enable-ProviderOpenAIAuth|Restore-ConfigIfUnchanged|configBackupPath|patchedConfigHash|configRestoreEligible'; then
  echo "[smoke] ERROR: Forbidden config mutation marker found in $CONTROLLER_SH" >&2
  exit 1
fi

if ! echo "$controller_text" | grep -q 'configManagedByPatch: false'; then
  echo "[smoke] ERROR: Controller does not declare configManagedByPatch: false" >&2
  exit 1
fi

if [[ "$SKIP_APP_CHECK" -eq 0 ]]; then
  config_path="${HOME}/.codex/config.toml"
  hash_before=""
  if [[ -f "$config_path" && -r "$config_path" ]]; then
    hash_before="$(shasum -a 256 "$config_path" 2>/dev/null | awk '{print $1}' || echo "")"
  fi

  echo "[smoke] Running diagnose action..."
  diag_out="$("$CONTROLLER_SH" diagnose)"
  echo "$diag_out" | node -e '
    const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
    if (d.platform !== "darwin") throw new Error("expected platform darwin");
    if (d.configManagedByPatch !== false) throw new Error("expected configManagedByPatch false");
  '

  if [[ -n "$hash_before" && -f "$config_path" && -r "$config_path" ]]; then
    hash_after="$(shasum -a 256 "$config_path" 2>/dev/null | awk '{print $1}' || echo "")"
    if [[ "$hash_before" != "$hash_after" ]]; then
      echo "[smoke] ERROR: diagnose modified config.toml" >&2
      exit 1
    fi
  fi
fi

# Determine bundle path for self-test if available
if [[ -z "$BUNDLE_PATH" && -f "/tmp/chatgpt_assets/app-primary-5433e23a397e.js" ]]; then
  BUNDLE_PATH="/tmp/chatgpt_assets/app-primary-5433e23a397e.js"
elif [[ -z "$BUNDLE_PATH" && -f "${HOME}/.gemini/antigravity/brain/345b2dcc-bd55-4698-b9fe-fb77947a1780/scratch/app-primary.js" ]]; then
  BUNDLE_PATH="${HOME}/.gemini/antigravity/brain/345b2dcc-bd55-4698-b9fe-fb77947a1780/scratch/app-primary.js"
fi

if [[ -n "$BUNDLE_PATH" && -f "$BUNDLE_PATH" ]]; then
  echo "[smoke] Running bundle self-test on $BUNDLE_PATH..."
  self_test_out="$(node "$SUPERVISOR" --self-test --gate "$GATE" --bundle "$BUNDLE_PATH")"
  echo "$self_test_out" | node -e '
    const res = JSON.parse(require("fs").readFileSync(0, "utf8"));
    if (!res.ok) throw new Error("self-test not ok");
    if (!["codex-local-quota", "local-submit-quota"].includes(res.location?.mode)) throw new Error("unexpected mode: " + res.location?.mode);
    if (!res.location?.quotaVariable) throw new Error("missing quotaVariable");
    if (res.location?.mode === "codex-local-quota" && !res.location?.hostVariable) throw new Error("missing hostVariable");
    if (!res.condition || !res.condition.includes("=false,false)")) throw new Error("unexpected condition");
  '
  echo "[smoke] Bundle self-test passed."
fi

echo "[smoke] All macOS smoke tests passed."

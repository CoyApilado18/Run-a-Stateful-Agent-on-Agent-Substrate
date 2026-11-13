#!/usr/bin/env bash
# teardown.sh: removes everything setup.sh created on your computer.
# It cannot delete your Gemini API key; that lives in your Google account (see the end).
set -euo pipefail

CLUSTER_NAME="kagent"   # must match setup.sh

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"
export PATH="$REPO_DIR/bin:$PATH"
PF_PID_FILE="$REPO_DIR/.ui-port-forward.pid"

printf '\033[1mCleaning up your local agent platform\033[0m\n\n'

if [ -f "$PF_PID_FILE" ] || pgrep -f "port-forward -n kagent service/kagent-ui" >/dev/null 2>&1; then
  [ -f "$PF_PID_FILE" ] && kill "$(cat "$PF_PID_FILE")" 2>/dev/null || true
  pkill -f "port-forward -n kagent service/kagent-ui" 2>/dev/null || true
  rm -f "$PF_PID_FILE" "$REPO_DIR/.ui-port-forward.log"
  printf '  ✅ Closed the kagent UI tunnel (http://localhost:8080)\n'
fi

if ! command -v kind >/dev/null 2>&1; then
  printf '  ⚠️  kind is not installed, so there is no cluster to delete.\n'
elif kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  printf '     Deleting the kind cluster (about 30 seconds)...\n'
  kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1
  printf '  ✅ Deleted kind cluster "%s". This removed, all at once:\n' "$CLUSTER_NAME"
  printf '       - kagent (UI, controller, your agents and chat history)\n'
  printf '       - Agent Substrate (WorkerPool, workers, actors, snapshots)\n'
  printf '       - the Kubernetes node container and its downloaded images\n'
else
  printf '  ✅ No kind cluster named "%s" found (already deleted)\n' "$CLUSTER_NAME"
fi
rm -f "$REPO_DIR/.kagent-config.yaml" "$REPO_DIR/.substrate-values.yaml"

printf '\n  Kept on your computer (delete them yourself if you like):\n'
printf '       - ./bin       the downloaded tools (kind, kubectl, helm, kagent, kubectl-ate, jq)\n'
printf '       - .env        your API key. Delete it with:  rm .env\n'
printf '       - setup.log   the setup log (contains no key)\n'

printf '\n\033[1m  ⚠️  One more step, on the web: delete your API key.\033[0m\n'
printf '     Deleting .env does NOT switch the key off. The key still works until you delete it:\n'
printf '       1. Open https://aistudio.google.com/apikey\n'
printf '       2. Find the key you made for this project\n'
printf '       3. Click the trash/delete icon and confirm\n\n'

#!/usr/bin/env bash
# status.sh: shows what Agent Substrate is doing under the hood.
#   ./status.sh          print the current state once
#   ./status.sh --watch  refresh every 2 seconds and log every sleep/wake (Ctrl+C to stop)
# Run it AFTER each chat message to see your agent's actor go to sleep and wake up.
set -euo pipefail

CLUSTER_NAME="kagent"   # must match setup.sh
NAMESPACE="kagent"
ATESPACE="kagent"
WORKER_POOL="kagent-default"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="$REPO_DIR/bin:$PATH"
CTX="kind-$CLUSTER_NAME"
PF_PID_FILE="$REPO_DIR/.ui-port-forward.pid"
UI_PORT="$(awk -F= '$1=="UI_PORT"{gsub(/[\r"'"'"' ]/,"",$2); print $2}' "$REPO_DIR/.env" 2>/dev/null || true)"
UI_PORT="${UI_PORT:-8080}"

WATCH=0
case "${1:-}" in
  --watch|-w) WATCH=1 ;;
  "") ;;
  *) echo "Usage: ./status.sh [--watch]"; exit 1 ;;
esac

for tool in kubectl kubectl-ate jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "❌ $tool not found. Run ./setup.sh first."; exit 1; }
done
if ! kubectl --context "$CTX" get namespace "$NAMESPACE" >/dev/null 2>&1; then
  echo "❌ Can't reach the cluster. Is Docker running? If you ran ./teardown.sh, run ./setup.sh again."
  exit 1
fi

ate() { kubectl ate --context "$CTX" "$@" 2>/dev/null; }

# Aligns tab-separated rows into columns (portable; no `column` needed).
table() {
  awk -F'\t' '{ for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > w[i]) w[i] = length($i) } if (NF > nf) nf = NF }
    END { for (r = 1; r <= NR; r++) { line = ""; for (i = 1; i <= nf; i++) line = line sprintf(i < nf ? "%-" w[i] + 2 "s" : "%s", cell[r, i]); print line } }'
}

# Keeps the UI tunnel (http://localhost:8080) alive; restarts it if it died.
ensure_ui_tunnel() {
  if curl -fsS "http://localhost:$UI_PORT" 2>/dev/null | grep -qi kagent; then return 0; fi
  pkill -f "port-forward -n $NAMESPACE service/kagent-ui" 2>/dev/null || true
  nohup kubectl --context "$CTX" port-forward -n "$NAMESPACE" service/kagent-ui "$UI_PORT:8080" \
    >"$REPO_DIR/.ui-port-forward.log" 2>&1 &
  echo $! >"$PF_PID_FILE"
  UI_NOTE=" (tunnel restarted)"
}

# Turns an ActorTemplate name like "ops-buddy-44ce8c927635" back into the agent name.
JQ_AGENT='def agent: (.actorTemplate.name // "?") | sub("-[0-9a-f]{12}$"; "");'

# State labels a beginner can read.
JQ_LABEL='def statelabel: {
  "ACTOR_STATE_RUNNING":    "RUNNING    (awake, on a worker)",
  "ACTOR_STATE_RESUMING":   "RESUMING   (waking up)",
  "ACTOR_STATE_SUSPENDING": "SUSPENDING (saving snapshot)",
  "ACTOR_STATE_SUSPENDED":  "SUSPENDED  (asleep, no worker)",
  "ACTOR_STATE_CRASHED":    "CRASHED",
  "ACTOR_STATE_DELETING":   "DELETING",
  "ACTOR_STATE_REVERTING":  "REVERTING"
}[.] // .;'

collect() {
  ACTORS_JSON="$(ate get actors -a "$ATESPACE" -o json || true)"
  [ -n "$ACTORS_JSON" ] || ACTORS_JSON='{"actors":[]}'
  WORKERS_JSON="$(ate get workers -o json || true)"
  [ -n "$WORKERS_JSON" ] || WORKERS_JSON='{"workers":[]}'
  POOL_JSON="$(kubectl --context "$CTX" get workerpool "$WORKER_POOL" -n "$NAMESPACE" -o json 2>/dev/null || echo '{}')"
  TEMPLATES_JSON="$(ate get actor-templates -a "$ATESPACE" -o json || true)"
  [ -n "$TEMPLATES_JSON" ] || TEMPLATES_JSON='{"actorTemplates":[]}'
  ROUTER_READY="$(kubectl --context "$CTX" get deployment atenet-router -n ate-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
}

# Substrate's own measurement of the last wake-up (atelet logs "Restore timing breakdown").
last_wake() {
  kubectl --context "$CTX" logs -n ate-system daemonset/atelet --all-containers --since=30m 2>/dev/null \
    | grep '"Restore timing breakdown"' | tail -n 1 \
    | jq -r '"\(."ate.template.name" | sub("-[0-9a-f]{12}$"; "")) woke up in \(."ate.actor.restore.duration.total" * 1000 | floor / 1000) s (snapshot restored into a \(."ate.sandbox.class") sandbox)"' 2>/dev/null || true
}

render() {
  local now; now="$(date +%H:%M:%S)"
  printf '\033[1mAgent Substrate status\033[0m   %s   atespace: %s   UI: http://localhost:%s%s\n\n' "$now" "$ATESPACE" "$UI_PORT" "${UI_NOTE:-}"

  # WorkerPool + workers
  local desired ready sandbox
  desired="$(jq -r '.spec.replicas // "?"' <<<"$POOL_JSON")"
  ready="$(jq -r '.status.readyReplicas // 0' <<<"$POOL_JSON")"
  sandbox="$(jq -r '.spec.sandboxConfigRef.name // .status.sandboxConfig // "gvisor-default"' <<<"$POOL_JSON")"
  printf '\033[1mWORKERPOOL\033[0m %s: %s of %s workers ready, sandbox: %s\n' "$WORKER_POOL" "$ready" "$desired" "$sandbox"
  jq -r --argjson a "$ACTORS_JSON" '
    ($a.actors // []) as $actors
    | (.workers // [])
    | map(select(.workerPool == "'"$WORKER_POOL"'"))
    | sort_by(.workerPod)
    | (["  WORKER POD", "STATE", "ACTORS ON IT", "BUSY?"] | @tsv),
      (.[] | . as $w
        | ($actors | map(select(.status.workerAssignment.workerPod == $w.workerPod)) | length) as $n
        | ["  " + ($w.workerPod // "?"),
           (($w.status.state // "?") | sub("WORKER_STATE_"; "")),
           ($n | tostring),
           (if $n > 0 then "busy" else "free" end)] | @tsv)
  ' <<<"$WORKERS_JSON" | table
  printf '\n'

  # Templates: one per agent; every new chat starts from its golden snapshot.
  printf '\033[1mTEMPLATES\033[0m (one per agent; each new chat starts from its golden snapshot)\n'
  if [ "$(jq '(.actorTemplates // []) | length' <<<"$TEMPLATES_JSON")" = "0" ]; then
    printf '  No templates yet. Create your agent in the kagent UI (Step 2).\n'
  else
    jq -r --arg sb "$sandbox" '
      (.actorTemplates // [])
      | sort_by(.metadata.name)
      | (["  AGENT", "TEMPLATE", "GOLDEN SNAPSHOT", "SANDBOX"] | @tsv),
        (.[] | ["  " + (.metadata.name | sub("-[0-9a-f]{12}$"; "")),
                .metadata.name,
                (if .status.goldenSnapshotStatus.goldenTag then "ready" else "building..." end),
                ($sb | sub("-default$"; ""))] | @tsv)
    ' <<<"$TEMPLATES_JSON" | table
  fi
  printf '\n'

  # Actors
  printf '\033[1mACTORS\033[0m (one per chat; each runs in its own gVisor sandbox)\n'
  local count; count="$(jq '(.actors // []) | length' <<<"$ACTORS_JSON")"
  if [ "$count" = "0" ]; then
    printf '  No actors yet. Open your agent in the kagent UI and start a chat.\n'
  else
    jq -r "$JQ_AGENT $JQ_LABEL"'
      (.actors // [])
      | sort_by(.metadata.createTime)
      | (["  AGENT", "CHAT", "STATE", "WORKER", "SNAPSHOT"] | @tsv),
        (.[] | ["  " + agent,
                ((.metadata.name // "") | .[-6:]),
                (.status.state | statelabel),
                (.status.workerAssignment.workerPod // "-"),
                ("#" + ([.status.snapshots[]?.generation] | max | tostring) + " saved")] | @tsv)
    ' <<<"$ACTORS_JSON" | table
  fi
  printf '\n'

  # Router + last wake-up
  if [ "${ROUTER_READY:-0}" -ge 1 ] 2>/dev/null; then
    printf '\033[1mROUTER\033[0m atenet-router is up: it wakes a sleeping actor when a message arrives.\n'
  else
    printf '\033[1mROUTER\033[0m atenet-router is not ready yet.\n'
  fi
  local wake; wake="$(last_wake)"
  [ -n "$wake" ] && printf '\033[1mLAST WAKE-UP\033[0m %s\n' "$wake"
  printf '\n'

  # Summary + savings
  jq -r --argjson a "$ACTORS_JSON" --arg pool "$WORKER_POOL" '
    ($a.actors // []) as $actors
    | ($actors | length) as $total
    | ($actors | map(select(.status.state == "ACTOR_STATE_SUSPENDED")) | length) as $asleep
    | ($total - $asleep) as $awake
    | ((.workers // []) | map(select(.workerPool == $pool and .status.state == "WORKER_STATE_ACTIVE"))) as $ws
    | ($ws | length) as $nw
    | ($ws | map(.workerPod as $p | select($actors | any(.status.workerAssignment.workerPod == $p))) | length) as $busy
    | "\u001b[1mSUMMARY\u001b[0m \($asleep) agent chat(s) asleep, \($awake) awake. \($busy) of \($nw) workers busy, \($nw - $busy) free.",
      (if $total > 1 then
        "\u001b[1mSAVINGS\u001b[0m \($total) agent chats are served by \($nw) shared workers (\($busy) busy right now).\n        Without Substrate, each chat would keep its own pod running: \($total) pods, all the time."
       else empty end)
  ' <<<"$WORKERS_JSON"
}

# Watch mode: remember each actor's last state so we can log sleep/wake events.
# (Plain "name<TAB>state" lines rather than an associative array: macOS ships bash 3.2.)
PREV_LIST=""
EVENTS=()
MAX_AWAKE=0
MAX_BUSY=0
FIRST_POLL=1
log_events() {
  local line name agent state worker gen next_list=""
  while IFS=$'\t' read -r name agent state worker gen; do
    [ -n "$name" ] || continue
    local prev
    prev="$(printf '%s\n' "$PREV_LIST" | awk -F'\t' -v n="$name" '$1 == n { print $2 }')"
    if [ -n "$prev" ] && [ "$prev" != "$state" ]; then
      case "$state" in
        ACTOR_STATE_RUNNING)   line="$agent woke up on worker $worker" ;;
        ACTOR_STATE_SUSPENDED) line="$agent fell asleep: snapshot #$gen saved, released its worker" ;;
        ACTOR_STATE_RESUMING)  line="$agent is waking up (message arrived)" ;;
        *)                     line="$agent is ${state#ACTOR_STATE_}" ;;
      esac
      EVENTS+=("$(date +%H:%M:%S)  $line")
    elif [ -z "$prev" ] && [ "$FIRST_POLL" = "0" ]; then
      EVENTS+=("$(date +%H:%M:%S)  new chat with $agent: actor created (${state#ACTOR_STATE_})")
    fi
    next_list="$next_list$name"$'\t'"$state"$'\n'
  done < <(jq -r "$JQ_AGENT"'(.actors // [])[] | [.metadata.name, agent, .status.state,
            (.status.workerAssignment.workerPod // "-"), ([.status.snapshots[]?.generation] | max | tostring)] | @tsv' <<<"$ACTORS_JSON")
  PREV_LIST="$next_list"
  FIRST_POLL=0
  local awake; awake="$(jq '[(.actors // [])[] | select(.status.state != "ACTOR_STATE_SUSPENDED")] | length' <<<"$ACTORS_JSON")"
  [ "$awake" -gt "$MAX_AWAKE" ] && MAX_AWAKE="$awake"
  local busy; busy="$(jq -r --argjson a "$ACTORS_JSON" '[(.workers // [])[] | .workerPod as $p
    | select(($a.actors // []) | any(.status.workerAssignment.workerPod == $p))] | length' <<<"$WORKERS_JSON")"
  [ "$busy" -gt "$MAX_BUSY" ] && MAX_BUSY="$busy"
  NOW_AWAKE="$awake"; NOW_BUSY="$busy"
  if [ "${#EVENTS[@]}" -gt 8 ]; then EVENTS=("${EVENTS[@]: -8}"); fi
}

ensure_ui_tunnel
if [ "$WATCH" = "0" ]; then
  collect
  render
  exit 0
fi

trap 'printf "\n"; exit 0' INT TERM
while true; do
  collect
  log_events
  frame="$(render)"
  printf '\033[H\033[2J%s\n' "$frame"
  total="$(jq '(.actors // []) | length' <<<"$ACTORS_JSON")"
  workers="$(jq -r '.status.readyReplicas // 0' <<<"$POOL_JSON")"
  printf '\n\033[1mSAVINGS TABLE\033[0m (since you started --watch)\n'
  { printf '  \tAGENT CHATS\tAWAKE\tWORKERS BUSY\tPODS WITHOUT SUBSTRATE\n'
    printf '  Right now\t%s\t%s\t%s of %s\t%s\n' "$total" "$NOW_AWAKE" "$NOW_BUSY" "$workers" "$total"
    printf '  Busiest moment\t%s\t%s\t%s of %s\t%s\n' "$total" "$MAX_AWAKE" "$MAX_BUSY" "$workers" "$total"
  } | table
  printf '\033[1mEVENTS\033[0m (newest last)\n'
  if [ "${#EVENTS[@]}" -eq 0 ]; then printf '  Waiting for something to happen... send your agent a message.\n'
  else printf '  %s\n' "${EVENTS[@]}"; fi
  printf '\nRefreshing every 2 seconds. Press Ctrl+C to stop.\n'
  sleep 2
done

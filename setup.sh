#!/usr/bin/env bash
# setup.sh: builds your local agent platform in one go.
#   1. Checks your computer (Docker, memory, CPUs, ports) and downloads tools into ./bin
#   2. Reads your Gemini key from .env
#   3. Creates a local Kubernetes cluster with kind
#   4. Installs Agent Substrate and kagent
#   5. Waits until everything is healthy
#   6. Adds the agent template + harness, then opens the kagent UI at http://localhost:8080
# Safe to run again: finished steps are skipped or updated in place.
# Full logs go to setup.log. Your API key is never printed or logged.
set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned versions. These are the ONLY place versions are set.
# kagent pins the matching Agent Substrate release itself; never bump one
# without the other (a mismatched pair breaks chat).
# ---------------------------------------------------------------------------
KAGENT_VERSION="v1.0.0-alpha16"
SUBSTRATE_VERSION="v0.6.0-alpha3"   # paired with kagent v1.0.0-alpha16 (used for kubectl-ate)
KIND_VERSION="v0.33.0"
KIND_NODE_IMAGE="kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5"
KUBECTL_VERSION="v1.37.0"
HELM_VERSION="v3.22.1"
JQ_VERSION="1.8.2"
GEMINI_MODEL="gemini-3.5-flash-lite"  # informational: kagent v1.0.0-alpha16 chart default (free tier, tool calling)

# kubectl-ate releases ship without checksum files, so the hashes are pinned here.
KUBECTL_ATE_SHA256_linux_amd64="bbebe540531aa0cd6b436b2f6a0665eca82feba2cb4942bb3e3f997c3c9c4ad1"
KUBECTL_ATE_SHA256_linux_arm64="8e8e21d7198b18eea85aea490b275f3472393f2f0982f55035306558d63a57ce"
KUBECTL_ATE_SHA256_darwin_amd64="431dbd3f716dc71ee887a6899b9896da0bd1f0c2341e57b35b7138290cc3d0a6"
KUBECTL_ATE_SHA256_darwin_arm64="119cc7f55c4ca9d853651052e0d03ecf066c9a9c18c4d1a17da15b2095e49f40"

CLUSTER_NAME="kagent"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
NAMESPACE="kagent"
WORKER_POOL="kagent-default"
MIN_CPUS=4
MIN_MEM_GB=6       # measured peak: 2.4 GiB for the whole cluster (5 agents, 4 awake at once)
LOW_MEM_MIN_GB=4

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"
BIN_DIR="$REPO_DIR/bin"
LOG_FILE="$REPO_DIR/setup.log"
PF_PID_FILE="$REPO_DIR/.ui-port-forward.pid"
export PATH="$BIN_DIR:$PATH"
mkdir -p "$BIN_DIR"
: >"$LOG_FILE"
TOTAL_STEPS=6
START_TIME=$SECONDS

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
step() { printf '\n\033[1mStep %s/%s: %s\033[0m\n' "$1" "$TOTAL_STEPS" "$2"; echo "=== Step $1/$TOTAL_STEPS: $2 ($(date))" >>"$LOG_FILE"; }
ok()   { printf '  ✅ %s\n' "$1"; }
bad()  { printf '  ❌ %s\n     Fix: %s\n' "$1" "$2"; }
warn() { printf '  ⚠️  %s\n' "$1"; }
info() { printf '     %s\n' "$1"; }

# Replaces the API key with **** in anything headed for the log or screen.
mask() { SECRET="${GEMINI_API_KEY:-}" awk '{ s = ENVIRON["SECRET"]; if (s != "") { while ((i = index($0, s)) > 0) $0 = substr($0, 1, i - 1) "****" substr($0, i + length(s)) } print; fflush() }'; }

# Runs a command with all output going (masked) to setup.log only.
run() { "$@" 2>&1 | mask >>"$LOG_FILE"; }

die() {
  printf '\n  ❌ %s\n' "$1"
  [ -n "${2:-}" ] && printf '     Fix: %s\n' "$2"
  if grep -qv '^===' "$LOG_FILE"; then
    printf '\n  Last lines of setup.log:\n'
    tail -n 15 "$LOG_FILE" | mask | sed 's/^/     | /'
  fi
  printf '\n  Full log: %s\n  Troubleshooting: README.md, section "Troubleshooting"\n' "$LOG_FILE"
  exit 1
}

k() { kubectl --context "$KUBE_CONTEXT" "$@"; }

# Polls until every pod in a namespace is Ready (finished Job pods are ignored).
# Re-lists pods each time, so pods replaced during an upgrade don't cause a hang.
wait_pods_ready() {
  local ns="$1" deadline=$((SECONDS + $2)) notready
  while [ $SECONDS -lt $deadline ]; do
    notready="$(k get pods -n "$ns" -o json 2>>"$LOG_FILE" | jq -r '[.items[]
      | select(.status.phase != "Succeeded")
      | select(.metadata.deletionTimestamp == null)
      | select(([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length) == 0)
      | .metadata.name] | join(" ")')" || notready="(unknown)"
    if [ -z "$notready" ]; then return 0; fi
    echo "waiting for pods in $ns: $notready" >>"$LOG_FILE"
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------------------
# Download helpers (everything goes into ./bin, no sudo needed)
# ---------------------------------------------------------------------------
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# fetch <url> <dest> <expected-sha256>
fetch() {
  local url="$1" dest="$2" want="$3" got
  curl -fsSL --retry 3 -o "$dest.tmp" "$url" >>"$LOG_FILE" 2>&1 || return 1
  got="$(sha256_of "$dest.tmp")"
  if [ "$got" != "$want" ]; then
    echo "checksum mismatch for $url: want $want got $got" >>"$LOG_FILE"
    rm -f "$dest.tmp"; return 1
  fi
  mv "$dest.tmp" "$dest"
}

# Reads the first field of a published checksum file.
remote_sha() { curl -fsSL --retry 3 "$1" 2>>"$LOG_FILE" | awk 'NR==1{print $1}'; }

# install_tool <name> <version-stamp> <function-that-downloads>
install_tool() {
  local name="$1" stamp="$BIN_DIR/.$1-$2"
  if [ -x "$BIN_DIR/$name" ] && [ -f "$stamp" ]; then ok "$name $2 (already in ./bin)"; return 0; fi
  if "$3"; then
    chmod +x "$BIN_DIR/$name"; rm -f "$BIN_DIR/.$name-"*; touch "$stamp"
    ok "$name $2 (downloaded to ./bin)"
  else
    bad "Could not download $name $2" "check your internet connection, then run ./setup.sh again"
    PREFLIGHT_FAILED=1
  fi
}

dl_kind() { fetch "https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-$OS-$ARCH" "$BIN_DIR/kind" \
  "$(remote_sha "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-$OS-$ARCH.sha256sum")"; }
dl_kubectl() { fetch "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$OS/$ARCH/kubectl" "$BIN_DIR/kubectl" \
  "$(remote_sha "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/$OS/$ARCH/kubectl.sha256")"; }
dl_kagent() { fetch "https://github.com/kagent-dev/kagent/releases/download/$KAGENT_VERSION/kagent-$OS-$ARCH" "$BIN_DIR/kagent" \
  "$(remote_sha "https://github.com/kagent-dev/kagent/releases/download/$KAGENT_VERSION/kagent-$OS-$ARCH.sha256")"; }
dl_kubectl_ate() {
  local var="KUBECTL_ATE_SHA256_${OS}_${ARCH}"
  fetch "https://github.com/kagent-dev/substrate/releases/download/$SUBSTRATE_VERSION/kubectl-ate-$OS-$ARCH" "$BIN_DIR/kubectl-ate" "${!var}"
}
dl_jq() {
  local jqos="$OS"; [ "$OS" = "darwin" ] && jqos="macos"
  local sum
  sum="$(curl -fsSL --retry 3 "https://github.com/jqlang/jq/releases/download/jq-$JQ_VERSION/sha256sum.txt" 2>>"$LOG_FILE" | awk -v f="jq-$jqos-$ARCH" '$2==f{print $1}')"
  fetch "https://github.com/jqlang/jq/releases/download/jq-$JQ_VERSION/jq-$jqos-$ARCH" "$BIN_DIR/jq" "$sum"
}
dl_helm() {
  local tgz="$BIN_DIR/helm.tgz" tmp="$BIN_DIR/helm-extract"
  fetch "https://get.helm.sh/helm-$HELM_VERSION-$OS-$ARCH.tar.gz" "$tgz" \
    "$(remote_sha "https://get.helm.sh/helm-$HELM_VERSION-$OS-$ARCH.tar.gz.sha256sum")" || return 1
  mkdir -p "$tmp" && tar -xzf "$tgz" -C "$tmp" && mv "$tmp/$OS-$ARCH/helm" "$BIN_DIR/helm"
  rm -rf "$tgz" "$tmp"
}

# ---------------------------------------------------------------------------
# Step 1: preflight checks
# ---------------------------------------------------------------------------
printf '\033[1mAgent Substrate + kagent setup\033[0m  (kagent %s, Substrate %s, Kubernetes %s)\n' \
  "$KAGENT_VERSION" "$SUBSTRATE_VERSION" "${KUBECTL_VERSION#v}"
printf 'Full logs: setup.log\n'

step 1 "Checking your computer"
PREFLIGHT_FAILED=0

case "$(uname -s)" in
  Darwin) OS="darwin"; OS_NAME="macOS" ;;
  Linux)
    OS="linux"; OS_NAME="Linux"
    if grep -qi microsoft /proc/version 2>/dev/null; then OS_NAME="Windows (WSL2)"; fi ;;
  *) OS=""; OS_NAME="$(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
  *) ARCH="" ;;
esac
if [ -z "$OS" ] || [ -z "$ARCH" ]; then
  bad "Unsupported system: $OS_NAME $(uname -m)" "use macOS, Linux, or Windows with WSL2 (Ubuntu)"
  exit 1
fi
ok "Operating system: $OS_NAME ($ARCH)"

# Settings from .env that preflight needs (the key itself is read in step 2).
read_env() { [ -f .env ] && awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); gsub(/\r/, ""); gsub(/^["'"'"' ]+|["'"'"' ]+$/, ""); print; exit }' .env || true; }
[ -z "${LOW_MEMORY:-}" ] && LOW_MEMORY="$(read_env LOW_MEMORY)"
[ -z "${UI_PORT:-}" ] && UI_PORT="$(read_env UI_PORT)"
UI_PORT="${UI_PORT:-8080}"


for tool in curl tar awk; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    bad "$tool is not installed" "install it (Ubuntu/WSL2: sudo apt-get install -y $tool), then run ./setup.sh again"
    PREFLIGHT_FAILED=1
  fi
done

# Docker: installed, running, and big enough.
DOCKER_DESKTOP=0
if ! command -v docker >/dev/null 2>&1; then
  bad "Docker is not installed" "install Docker (see NEXTWORK.md, Step 1), start it, then run ./setup.sh again"
  PREFLIGHT_FAILED=1
elif ! docker info >/dev/null 2>"$BIN_DIR/.docker-err"; then
  if grep -qi "permission denied" "$BIN_DIR/.docker-err"; then
    bad "Docker is running but your user can't use it" "run: sudo usermod -aG docker \$USER   then log out and back in"
  else
    bad "Docker is installed but not running" "start Docker (macOS/Windows: open Docker Desktop; Linux: sudo systemctl start docker), wait until it says running, then run ./setup.sh again"
  fi
  PREFLIGHT_FAILED=1
else
  ok "Docker is running"
  DOCKER_OS="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)"
  case "$DOCKER_OS" in *"Docker Desktop"*) DOCKER_DESKTOP=1 ;; esac
  DOCKER_CPUS="$(docker info --format '{{.NCPU}}' 2>/dev/null || echo 0)"
  DOCKER_MEM_GB="$(docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%.1f", $1/1024/1024/1024}')"
  NEED_MEM="$MIN_MEM_GB"; [ "${LOW_MEMORY:-}" = "1" ] && NEED_MEM="$LOW_MEM_MIN_GB"
  if [ "$DOCKER_CPUS" -lt "$MIN_CPUS" ]; then
    bad "Docker has $DOCKER_CPUS CPUs (need $MIN_CPUS+)" "give Docker more CPUs (Docker Desktop: Settings > Resources), then run ./setup.sh again"
    PREFLIGHT_FAILED=1
  else
    ok "Docker CPUs: $DOCKER_CPUS"
  fi
  if awk -v m="$DOCKER_MEM_GB" -v n="$NEED_MEM" 'BEGIN{exit !(m+0.5 < n)}'; then
    bad "Docker has ${DOCKER_MEM_GB} GB memory (need ${NEED_MEM}+ GB)" "give Docker more memory (Docker Desktop: Settings > Resources), or add LOW_MEMORY=1 to .env"
    PREFLIGHT_FAILED=1
  else
    ok "Docker memory: ${DOCKER_MEM_GB} GB"
  fi
  if [ "$OS" = "linux" ] && [ "$DOCKER_DESKTOP" = "0" ] && [ -r /proc/meminfo ]; then
    FREE_GB="$(awk '/^MemAvailable:/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)"
    if awk -v m="$FREE_GB" -v n="$NEED_MEM" 'BEGIN{exit !(m < n)}'; then
      warn "Only ${FREE_GB} GB of memory is free right now. Close big apps (browsers, IDEs) or add LOW_MEMORY=1 to .env."
    fi
  fi
fi

# Known risk: gVisor snapshots (sleep/wake) often fail under Docker Desktop.
if [ "$DOCKER_DESKTOP" = "1" ] || [ "$OS" = "darwin" ]; then
  warn "Heads up: you're using Docker Desktop or a Mac."
  info "kagent's own guide warns that Docker Desktop often fails Agent Substrate's"
  info "gVisor snapshot step, so the agent may not sleep and wake correctly."
  if [ "$OS" = "darwin" ] && [ "$ARCH" = "arm64" ]; then
    info "On Apple Silicon there is also an open bug where waking from a snapshot fails"
    info "(github.com/agent-substrate/substrate/issues/1769)."
  fi
  info "Setup will continue. If Step 3 or 4 fails, see README.md > Troubleshooting."
fi

# Linux/WSL2: kind needs enough inotify watchers or pods fail with "too many open files".
if [ "$OS" = "linux" ] && [ -r /proc/sys/fs/inotify/max_user_instances ]; then
  if [ "$(cat /proc/sys/fs/inotify/max_user_instances)" -lt 512 ]; then
    warn "File-watch limit is low; pods may fail with \"too many open files\"."
    info "Fix: sudo sysctl fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288"
  fi
fi

# The UI port must be free, unless it's our own tunnel from an earlier run.
# Port already serving the kagent UI = our own tunnel from an earlier run.
OUR_PF=0
if curl -fsS "http://localhost:$UI_PORT" 2>/dev/null | grep -qi kagent; then OUR_PF=1; fi
if [ "$OUR_PF" = "0" ] && (exec 3<>"/dev/tcp/127.0.0.1/$UI_PORT") 2>/dev/null; then
  bad "Port $UI_PORT is already in use" "close the app using it, or add UI_PORT=8090 to .env"
  PREFLIGHT_FAILED=1
elif [ "$OUR_PF" = "1" ]; then
  ok "Port $UI_PORT already has your kagent UI tunnel (it will be refreshed)"
else
  ok "Port $UI_PORT is free for the kagent UI"
fi

if [ "$PREFLIGHT_FAILED" = "0" ]; then
  info "Downloading pinned tools into ./bin (first run only)..."
  install_tool kind "$KIND_VERSION" dl_kind
  install_tool kubectl "$KUBECTL_VERSION" dl_kubectl
  install_tool helm "$HELM_VERSION" dl_helm
  install_tool kagent "$KAGENT_VERSION" dl_kagent
  install_tool kubectl-ate "$SUBSTRATE_VERSION" dl_kubectl_ate
  install_tool jq "$JQ_VERSION" dl_jq
fi

if [ "$PREFLIGHT_FAILED" != "0" ]; then
  printf '\n❌ Fix the items marked ❌ above, then run ./setup.sh again.\n'
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: read the API key from .env
# ---------------------------------------------------------------------------
step 2 "Reading your Gemini key from .env"
if [ ! -f .env ]; then
  die "No .env file found" "run: cp .env.example .env   then paste your key after GEMINI_API_KEY= and run ./setup.sh again"
fi
GEMINI_API_KEY="$(read_env GEMINI_API_KEY)"
if [ -z "$GEMINI_API_KEY" ]; then
  die "GEMINI_API_KEY in .env is empty" "open .env, paste your Google AI Studio key after GEMINI_API_KEY= (no spaces), save, and run ./setup.sh again"
fi
case "$GEMINI_API_KEY" in
  *" "*|*"<"*|*">"*|your*|YOUR*|paste*|PASTE*)
    die "GEMINI_API_KEY in .env doesn't look like a real key" "paste the key exactly as Google AI Studio shows it, with no spaces or quotes" ;;
esac
ok "Key found (${#GEMINI_API_KEY} characters, hidden)"
WORKERS=2
if [ "$LOW_MEMORY" = "1" ]; then WORKERS=1; ok "LOW_MEMORY=1: using 1 worker instead of 2"; fi

# ---------------------------------------------------------------------------
# Step 3: create the kind cluster
# ---------------------------------------------------------------------------
step 3 "Creating your Kubernetes cluster (kind, Kubernetes ${KUBECTL_VERSION#v})"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  NODE_IMAGE="$(docker inspect "${CLUSTER_NAME}-control-plane" --format '{{.Config.Image}}' 2>/dev/null || true)"
  if [ "$NODE_IMAGE" != "$KIND_NODE_IMAGE" ] && [ "${NODE_IMAGE%@*}" != "${KIND_NODE_IMAGE%@*}" ]; then
    die "A cluster named '$CLUSTER_NAME' exists but runs a different Kubernetes version ($NODE_IMAGE)" "run ./teardown.sh, then ./setup.sh again"
  fi
  docker start "${CLUSTER_NAME}-control-plane" >>"$LOG_FILE" 2>&1 || true
  run kind export kubeconfig --name "$CLUSTER_NAME"
  ok "Cluster '$CLUSTER_NAME' already exists, reusing it"
else
  info "Downloading the Kubernetes node image can take a few minutes the first time..."
  run kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE" --wait 180s \
    || die "Could not create the kind cluster" "make sure Docker is running and has enough memory, then run ./setup.sh again"
  ok "Cluster '$CLUSTER_NAME' created"
fi
run kubectl config use-context "$KUBE_CONTEXT"
k wait --for=condition=Ready node --all --timeout=180s >>"$LOG_FILE" 2>&1 \
  || die "The cluster node did not become Ready" "run ./teardown.sh, then ./setup.sh again"
ok "Cluster node is Ready"

# ---------------------------------------------------------------------------
# Step 4: install Agent Substrate + kagent
# The kagent CLI installs, in order: kagent CRDs, Substrate CRDs, the pod
# certificate controller, PostgreSQL, Agent Substrate (ate-system), then kagent.
# Each part must be healthy before the next one starts.
# ---------------------------------------------------------------------------
step 4 "Installing Agent Substrate and kagent (this can take 5-10 minutes)"
info "Agent Substrate goes into the 'ate-system' namespace, kagent into '$NAMESPACE'."
info "While you wait: read about the WorkerPool in NEXTWORK.md, Step 1."
install_ok=0
# kagent's install reads its settings from a small config file: use Gemini
# (the default would be OpenAI), plus one Agent Substrate setting.
KAGENT_CONFIG="$REPO_DIR/.kagent-config.yaml"
SUBSTRATE_VALUES="$REPO_DIR/.substrate-values.yaml"
cat >"$KAGENT_CONFIG" <<EOF
install:
  defaultModelProvider: Gemini
  substrate:
    valuesFiles: [$SUBSTRATE_VALUES]
EOF
# Lets `kubectl ate` (used by status.sh) read Substrate without a login token.
# This is Substrate's own development default; fine for a local learning cluster,
# never for a shared one. The first entry is kagent's own controller.
cat >"$SUBSTRATE_VALUES" <<EOF
ateApi:
  authorization:
    bootstrapOwners:
      - "spiffe://cluster.local/ns/$NAMESPACE/sa/kagent-controller"
      - "system:serviceaccount:ate-system:ate-client"
EOF
for attempt in 1 2; do
  # The key is passed through the environment only, never on a command line we print.
  if ( export GOOGLE_API_KEY="$GEMINI_API_KEY" GEMINI_API_KEY="$GEMINI_API_KEY"
       run kagent --config "$KAGENT_CONFIG" install --namespace "$NAMESPACE" ); then
    install_ok=1; break
  fi
  if [ "$attempt" = "1" ]; then info "First attempt didn't finish (often slow image downloads). Retrying once..."; fi
done
if [ "$install_ok" != "1" ] || ! grep -q "kagent installed successfully" "$LOG_FILE"; then
  die "kagent install did not finish" "run ./setup.sh again (it resumes where it stopped). If it fails twice, see README.md > Troubleshooting"
fi
ok "Agent Substrate and kagent installed"

# ---------------------------------------------------------------------------
# Step 5: wait until everything is healthy
# ---------------------------------------------------------------------------
step 5 "Waiting for everything to be healthy (up to 10 minutes)"
wait_pods_ready ate-system 600 \
  || die "Agent Substrate (ate-system) pods are not Ready" "run: ./bin/kubectl get pods -n ate-system   and see README.md > Troubleshooting"
ok "Agent Substrate is ready (ate-system)"
k wait --namespace "$NAMESPACE" --for=condition=Available deployment/kagent-controller --timeout=600s >>"$LOG_FILE" 2>&1 \
  || die "The kagent controller did not start" "run ./setup.sh again; if it still fails see README.md > Troubleshooting"
k wait --namespace "$NAMESPACE" --for=condition=Available deployment --all --timeout=600s >>"$LOG_FILE" 2>&1 \
  || die "Some kagent parts did not start" "run: ./bin/kubectl get pods -n $NAMESPACE   and see README.md > Troubleshooting"
ok "kagent controller and UI are ready"

run k scale workerpool "$WORKER_POOL" -n "$NAMESPACE" --replicas="$WORKERS" \
  || die "Could not size the WorkerPool" "run ./setup.sh again"
k wait --namespace "$NAMESPACE" --for=jsonpath='{.status.readyReplicas}'="$WORKERS" "workerpool/$WORKER_POOL" --timeout=600s >>"$LOG_FILE" 2>&1 \
  || die "The WorkerPool's workers did not become ready" "see README.md > Troubleshooting (WorkerPool not ready)"
ok "WorkerPool '$WORKER_POOL' has $WORKERS ready worker(s)"

# ---------------------------------------------------------------------------
# Step 6: open the UI tunnel
# ---------------------------------------------------------------------------
step 6 "Adding your agent's building blocks and opening the kagent UI"
run k apply -f manifests/kubernetes-agent.yaml \
  || die "Could not apply manifests/kubernetes-agent.yaml" "run ./setup.sh again"
ok "Added the 'kubernetes-agent' template and 'substrate-harness' (you'll use them in Step 2)"
# Restart the UI tunnel so it points at the freshly installed UI.
if [ -f "$PF_PID_FILE" ]; then kill "$(cat "$PF_PID_FILE")" 2>/dev/null || true; rm -f "$PF_PID_FILE"; fi
pkill -f "port-forward -n $NAMESPACE service/kagent-ui" 2>/dev/null || true
sleep 1
nohup kubectl --context "$KUBE_CONTEXT" port-forward -n "$NAMESPACE" service/kagent-ui "$UI_PORT:8080" \
  >"$REPO_DIR/.ui-port-forward.log" 2>&1 &
echo $! >"$PF_PID_FILE"
ui_up=0
for _ in $(seq 1 15); do
  if curl -fsS -o /dev/null "http://localhost:$UI_PORT" 2>/dev/null; then ui_up=1; break; fi
  sleep 1
done
if [ "$ui_up" = "1" ]; then ok "kagent UI is reachable"; else warn "The UI tunnel is still starting; ./status.sh restarts it if needed"; fi

ELAPSED=$((SECONDS - START_TIME))
printf '\n\033[1m🎉 Your agent platform is ready!\033[0m  (took %dm %02ds)\n\n' $((ELAPSED / 60)) $((ELAPSED % 60))
printf '  Open the kagent UI:   \033[1mhttp://localhost:%s\033[0m\n\n' "$UI_PORT"
printf '  If the page does not load, reopen the tunnel with this command\n'
printf '  (leave that terminal open while you use the UI):\n'
printf '    ./bin/kubectl --context %s port-forward -n %s service/kagent-ui %s:8080\n\n' "$KUBE_CONTEXT" "$NAMESPACE" "$UI_PORT"
printf '  See what is happening under the hood:   ./status.sh\n'
printf '  When you are done:                      ./teardown.sh\n'

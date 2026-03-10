#!/opt/homebrew/bin/bash
# =============================================================================
# cluster.sh — Start, stop, or restart the macOS GPU AI stack
# Usage: ./cluster.sh [start|stop|restart|status]
# =============================================================================
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "ERROR: bash 4+ required. Install with: brew install bash" >&2
  echo "       Then run with: /opt/homebrew/bin/bash cluster.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}==> $*${RESET}"; }

# --- Read config -------------------------------------------------------------
MACHINE_NAME=$(awk '/^podman:/{f=1} f && /machine_name:/{gsub(/.*: */,""); gsub(/"/,""); print; exit}' "$CONFIG_FILE")
KIND_CLUSTER_NAME=$(awk '/^kind:/{f=1} f && /cluster_name:/{gsub(/.*: */,""); gsub(/"/,""); print; exit}' "$CONFIG_FILE")

[[ -n "$MACHINE_NAME" ]]      || error "Could not read podman.machine_name from config.yaml"
[[ -n "$KIND_CLUSTER_NAME" ]] || error "Could not read kind.cluster_name from config.yaml"

# --- SSH into VM as root -----------------------------------------------------
vm_ssh() {
  local ssh_key port
  ssh_key=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.IdentityPath}}')
  port=$(podman machine inspect "$MACHINE_NAME" --format '{{.SSHConfig.Port}}')
  ssh -i "$ssh_key" -p "$port" \
      -o StrictHostKeyChecking=no \
      -o LogLevel=ERROR \
      "root@localhost" "$@"
}

# =============================================================================
# STOP
# =============================================================================
do_stop() {
  step "Stopping stack"

  info "Stopping kind control plane container..."
  vm_ssh "podman stop ${KIND_CLUSTER_NAME}-control-plane" 2>/dev/null && \
    success "Control plane stopped" || warn "Control plane was not running"

  info "Stopping Podman machine..."
  podman machine stop "$MACHINE_NAME" && \
    success "Podman machine stopped" || warn "Podman machine was not running"

  info "Killing stray gvproxy processes..."
  pkill -f gvproxy 2>/dev/null && success "gvproxy killed" || warn "gvproxy not running"
}

# =============================================================================
# START
# =============================================================================
do_start() {
  step "Starting stack"

  info "Starting Podman machine..."
  podman machine start "$MACHINE_NAME" || warn "machine start returned non-zero — checking connectivity anyway"

  info "Setting rootful connection as default..."
  podman system connection default "${MACHINE_NAME}-root" || \
    error "Could not set rootful connection. Run: podman system connection list"

  info "Waiting for Podman machine to be ready..."
  local timeout=180 elapsed=0
  until podman info &>/dev/null 2>&1; do
    (( elapsed >= timeout )) && error "Timed out waiting for Podman machine"
    sleep 5; (( elapsed += 5 ))
    info "  Still waiting... (${elapsed}s / ${timeout}s)"
  done
  success "Podman machine is ready"

  info "Starting kind control plane container..."
  vm_ssh "podman start ${KIND_CLUSTER_NAME}-control-plane" && \
    success "Control plane started" || warn "Could not start control plane — it may already be running"

  info "Refreshing kubeconfig..."
  local podman_sock
  podman_sock=$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)
  export DOCKER_HOST="unix://${podman_sock}"
  export KIND_EXPERIMENTAL_PROVIDER=podman
  kind export kubeconfig --name "$KIND_CLUSTER_NAME"
  success "kubeconfig refreshed"

  info "Waiting for cluster node to be Ready..."
  local timeout=120 elapsed=0
  until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
    (( elapsed >= timeout )) && error "Timed out waiting for cluster node"
    sleep 5; (( elapsed += 5 ))
    info "  Still waiting... (${elapsed}s / ${timeout}s)"
  done
  success "Cluster node is Ready"

  do_status
}

# =============================================================================
# STATUS
# =============================================================================
do_status() {
  step "Stack status"

  local machine_state
  machine_state=$(podman machine inspect "$MACHINE_NAME" --format '{{.State}}' 2>/dev/null || echo "unknown")
  if [[ "$machine_state" == "running" ]]; then
    success "Podman machine:   running"
  else
    warn    "Podman machine:   $machine_state"
  fi

  local node_status
  node_status=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1 || echo "unreachable")
  if [[ "$node_status" == "Ready" ]]; then
    success "Cluster node:     Ready"
  else
    warn    "Cluster node:     $node_status"
  fi

  echo ""
  info "Pods:"
  kubectl get pods -A 2>/dev/null || warn "Could not reach cluster"
}

# =============================================================================
# MAIN
# =============================================================================
CMD="${1:-status}"

echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════╗"
echo "  ║   macOS GPU AI Stack                  ║"
echo "  ║   Podman + krunkit + kind + helm      ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${RESET}"

case "$CMD" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; do_start ;;
  status)  do_status ;;
  *)
    echo "Usage: /opt/homebrew/bin/bash cluster.sh [start|stop|restart|status]"
    exit 1
    ;;
esac
#!/opt/homebrew/bin/bash
# =============================================================================
# setup.sh — Install and configure Podman/krunkit/kind/helm GPU stack on macOS
# =============================================================================
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "ERROR: bash 4+ required. Install with: brew install bash" >&2
  echo "       Then run with: /opt/homebrew/bin/bash setup.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/config.yaml}"

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}==> $*${RESET}"; }

# SSH directly into the Podman VM as root
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
# 1. CONFIG LOADING
# =============================================================================
get_yaml_value() {
  local file="$1" section="$2" key="$3"
  awk -v section="$section" -v key="$key" '
    $0 ~ "^"section":" { in_section=1; next }
    in_section && /^[a-zA-Z]/ { in_section=0 }
    in_section && $0 ~ "^[[:space:]]+"key":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
      gsub(/"/, "")
      print; exit
    }
  ' "$file"
}

get_yaml_list() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^"key":" { found=1; next }
    found && /^[a-zA-Z]/ { exit }
    found && /^[[:space:]]*-[[:space:]]/ {
      sub(/^[[:space:]]*-[[:space:]]*/, "")
      gsub(/"/, "")
      print
    }
  ' "$file"
}

load_helm_releases() {
  local file="$1"
  HELM_NAMES=(); HELM_CHARTS=(); HELM_NAMESPACES=()
  local names charts namespaces
  names=$(awk '/^helm:/{found=1} found && /name:/{ gsub(/^[^:]+:[[:space:]]*/,""); gsub(/"/,""); gsub(/[[:space:]]/,""); print}' "$file")
  charts=$(awk '/^helm:/{found=1} found && /chart:/{ gsub(/^[^:]+:[[:space:]]*/,""); gsub(/"/,""); gsub(/[[:space:]]/,""); print}' "$file")
  namespaces=$(awk '/^helm:/{found=1} found && /namespace:/{ gsub(/^[^:]+:[[:space:]]*/,""); gsub(/"/,""); gsub(/[[:space:]]/,""); print}' "$file")
  mapfile -t HELM_NAMES      <<< "$names"
  mapfile -t HELM_CHARTS_REL <<< "$charts"
  mapfile -t HELM_NAMESPACES <<< "$namespaces"
  HELM_CHARTS=()
  for c in "${HELM_CHARTS_REL[@]}"; do
    HELM_CHARTS+=("$SCRIPT_DIR/$c")
  done
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || error "Config file not found at: $CONFIG_FILE"
  info "Loading config from: $CONFIG_FILE"

  MACHINE_NAME=$(get_yaml_value  "$CONFIG_FILE" "podman"  "machine_name")
  MACHINE_CPU=$(get_yaml_value   "$CONFIG_FILE" "podman"  "cpu")
  MACHINE_MEM=$(get_yaml_value   "$CONFIG_FILE" "podman"  "memory")
  MACHINE_DISK=$(get_yaml_value  "$CONFIG_FILE" "podman"  "disk")

  KIND_CONFIG="$SCRIPT_DIR/$(get_yaml_value       "$CONFIG_FILE" "paths"  "kind_config")"
  OLLAMA_DOCKERFILE="$SCRIPT_DIR/$(get_yaml_value "$CONFIG_FILE" "paths"  "ollama_dockerfile")"

  KIND_CLUSTER_NAME=$(get_yaml_value "$CONFIG_FILE" "kind"    "cluster_name")
  OLLAMA_IMAGE=$(get_yaml_value      "$CONFIG_FILE" "ollama"  "image")
  KRUNKIT_TAP=$(get_yaml_value       "$CONFIG_FILE" "krunkit" "brew_tap")
  KRUNKIT_PKG=$(get_yaml_value       "$CONFIG_FILE" "krunkit" "brew_pkg")

  NAMESPACES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && NAMESPACES+=("$line")
  done < <(get_yaml_list "$CONFIG_FILE" "namespaces")

  load_helm_releases "$CONFIG_FILE"

  local missing=()
  [[ -z "$MACHINE_NAME"      ]] && missing+=("podman.machine_name")
  [[ -z "$MACHINE_CPU"       ]] && missing+=("podman.cpu")
  [[ -z "$MACHINE_MEM"       ]] && missing+=("podman.memory")
  [[ -z "$MACHINE_DISK"      ]] && missing+=("podman.disk")
  [[ -z "$KIND_CLUSTER_NAME" ]] && missing+=("kind.cluster_name")
  [[ -z "$OLLAMA_IMAGE"      ]] && missing+=("ollama.image")
  [[ ${#missing[@]} -gt 0 ]] && error "Config missing required fields: ${missing[*]}"

  success "Config loaded"
  info "  Machine:    $MACHINE_NAME (${MACHINE_CPU} cpu, ${MACHINE_MEM}MB, ${MACHINE_DISK}GB)"
  info "  Cluster:    $KIND_CLUSTER_NAME"
  info "  Namespaces: ${NAMESPACES[*]}"
  info "  Helm:       ${HELM_NAMES[*]}"
  info "  Ollama:     $OLLAMA_IMAGE"
}

# =============================================================================
# 2. PREREQUISITE CHECKS
# =============================================================================
check_prerequisites() {
  step "Checking prerequisites"
  command -v brew &>/dev/null || error "Homebrew not found. Install from https://brew.sh"
  success "Homebrew found"
  [[ -f "$KIND_CONFIG"       ]] || error "kind config not found at $KIND_CONFIG"
  success "kind config found: $KIND_CONFIG"
  [[ -f "$OLLAMA_DOCKERFILE" ]] || error "Ollama Dockerfile not found at $OLLAMA_DOCKERFILE"
  success "Ollama Dockerfile found: $OLLAMA_DOCKERFILE"
  for i in "${!HELM_NAMES[@]}"; do
    [[ -d "${HELM_CHARTS[$i]}" ]] || \
      error "Helm chart '${HELM_NAMES[$i]}' not found at ${HELM_CHARTS[$i]}"
    success "Helm chart found: ${HELM_NAMES[$i]} → ${HELM_CHARTS[$i]}"
  done
}

# =============================================================================
# 3. INSTALL TOOLS
# =============================================================================
install_brew_pkg() {
  local cmd="$1" pkg="${2:-$1}" cask="${3:-}"
  if command -v "$cmd" &>/dev/null; then
    warn "$cmd already installed — skipping"; return 0
  fi
  info "Installing $cmd..."
  [[ "$cask" == "cask" ]] && brew install --cask "$pkg" || brew install "$pkg"
  success "$cmd installed"
}

install_tools() {
  step "Installing required tools"
  install_brew_pkg "podman"
  install_brew_pkg "podman-desktop" "podman-desktop" "cask"
  install_brew_pkg "kind"
  install_brew_pkg "helm"
  if command -v krunkit &>/dev/null; then
    warn "krunkit already installed — skipping"
  else
    info "Installing krunkit via brew tap $KRUNKIT_TAP..."
    brew tap "$KRUNKIT_TAP"
    brew install "$KRUNKIT_PKG"
    success "krunkit installed"
  fi
  # krunkit depends on libkrun-efi which is pulled in automatically as a brew dependency.
}

# =============================================================================
# 4. PODMAN MACHINE
# =============================================================================
setup_podman_machine() {
  step "Setting up Podman machine"

  if podman machine list --format '{{.Name}}' 2>/dev/null | sed 's/\*$//' | grep -q "^${MACHINE_NAME}$"; then
    warn "Podman machine '$MACHINE_NAME' already exists — skipping init"
  else
    info "Creating Podman machine '$MACHINE_NAME'..."
    podman machine init \
      --cpus      "$MACHINE_CPU" \
      --memory    "$MACHINE_MEM" \
      --disk-size "$MACHINE_DISK" \
      --rootful \
      "$MACHINE_NAME"
    success "Podman machine '$MACHINE_NAME' created"
  fi

  local state
  state=$(podman machine inspect "$MACHINE_NAME" --format '{{.State}}' 2>/dev/null || echo "unknown")
  if [[ "$state" == "running" ]]; then
    info "Podman machine '$MACHINE_NAME' is already running"
  else
    info "Starting Podman machine '$MACHINE_NAME'..."
    podman machine start "$MACHINE_NAME" || warn "machine start returned non-zero — checking connectivity anyway"
  fi

  # Always use the rootful connection so kind can create privileged containers
  info "Setting rootful connection as default..."
  podman system connection default "${MACHINE_NAME}-root" 2>/dev/null || \
    error "Could not set rootful connection '${MACHINE_NAME}-root'. Run: podman system connection list"

  # Verify we are actually rootful before continuing
  local rootless
  rootless=$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo "unknown")
  [[ "$rootless" == "false" ]] || error "Podman is still running rootless — cannot continue. Check: podman system connection list"
  success "Podman is running rootful"

  info "Waiting for Podman machine to be ready..."
  local timeout=180 elapsed=0
  until podman info &>/dev/null 2>&1; do
    (( elapsed >= timeout )) && error "Timed out waiting for Podman machine"
    sleep 5; (( elapsed += 5 ))
    info "  Still waiting... (${elapsed}s / ${timeout}s)"
  done
  success "Podman machine '$MACHINE_NAME' is ready"
}

# =============================================================================
# 5. KIND CLUSTER
# =============================================================================
setup_kind_cluster() {
  step "Setting up kind cluster"

  # Use the rootful Podman socket — kind runs from the Mac terminal directly
  local podman_sock
  podman_sock=$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)
  [[ -n "$podman_sock" ]] || error "Could not determine Podman socket path"

  export DOCKER_HOST="unix://${podman_sock}"
  export KIND_EXPERIMENTAL_PROVIDER=podman
  info "Using Podman socket: $podman_sock"

  if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
    warn "kind cluster '$KIND_CLUSTER_NAME' already exists — skipping"
  else
    info "Creating kind cluster '$KIND_CLUSTER_NAME'..."
    kind create cluster --config "$KIND_CONFIG" --name "$KIND_CLUSTER_NAME"
    success "kind cluster '$KIND_CLUSTER_NAME' created"
  fi

  info "Waiting for cluster node to be Ready..."
  local timeout=120 elapsed=0
  until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
    (( elapsed >= timeout )) && error "Timed out waiting for cluster node"
    sleep 5; (( elapsed += 5 ))
    info "  Still waiting... (${elapsed}s / ${timeout}s)"
  done
  success "Cluster node is Ready"
}

# =============================================================================
# 6. BUILD AND LOAD OLLAMA IMAGE
# =============================================================================
build_and_load_ollama_image() {
  step "Building and loading Ollama image"

  local image_name="${OLLAMA_IMAGE%%:*}"
  local image_tag="${OLLAMA_IMAGE##*:}"
  local vm_tar="/root/tmp/${image_name}-${image_tag}.tar"
  local vm_build_dir="/root/tmp/ollama-build"

  vm_ssh "mkdir -p /root/tmp"

  # Check if already loaded in kind node
  local already_loaded
  already_loaded=$(vm_ssh "podman exec ${KIND_CLUSTER_NAME}-control-plane \
    crictl images 2>/dev/null | grep -c '${image_name}'" || echo "0")
  if [[ "${already_loaded:-0}" -gt 0 ]]; then
    warn "Image '$OLLAMA_IMAGE' already loaded in kind — skipping"
    return 0
  fi

  [[ -f "$OLLAMA_DOCKERFILE" ]] || error "Ollama Dockerfile not found at $OLLAMA_DOCKERFILE"

  # Copy build context into VM
  info "Copying Dockerfile context into VM..."
  vm_ssh "mkdir -p $vm_build_dir"
  tar -C "$(dirname "$OLLAMA_DOCKERFILE")" -cf - . | \
    vm_ssh "tar -C $vm_build_dir -xf -"
  success "Build context copied to VM"

  # Build inside VM (where /dev/dri exists)
  info "Building '$OLLAMA_IMAGE' inside VM..."
  vm_ssh "podman build --device /dev/dri \
    -f ${vm_build_dir}/$(basename "$OLLAMA_DOCKERFILE") \
    -t $OLLAMA_IMAGE \
    $vm_build_dir" || error "Failed to build Ollama image"
  success "Image '$OLLAMA_IMAGE' built"

  # Save inside VM
  info "Saving image to tar inside VM..."
  vm_ssh "podman save -o $vm_tar $OLLAMA_IMAGE" || error "Failed to save image"
  success "Image saved to $vm_tar inside VM"

  # Load into kind node
  info "Loading image into kind cluster..."
  vm_ssh "podman cp $vm_tar ${KIND_CLUSTER_NAME}-control-plane:/tmp/ && \
    podman exec ${KIND_CLUSTER_NAME}-control-plane \
    ctr -n k8s.io images import /tmp/$(basename $vm_tar) && \
    podman exec ${KIND_CLUSTER_NAME}-control-plane \
    rm -f /tmp/$(basename $vm_tar)" || error "Failed to load image into kind"
  success "Image '$OLLAMA_IMAGE' loaded into kind cluster"

  vm_ssh "rm -f $vm_tar"
}

# =============================================================================
# 7. NAMESPACES
# =============================================================================
create_namespaces() {
  step "Creating Kubernetes namespaces"
  for ns in "${NAMESPACES[@]}"; do
    if kubectl get namespace "$ns" &>/dev/null; then
      warn "Namespace '$ns' already exists — skipping"
    else
      kubectl create namespace "$ns"
      success "Namespace '$ns' created"
    fi
  done
}

# =============================================================================
# 8. HELM INSTALLS
# =============================================================================
tail_ollama_init_logs() {
  local ns="$1"
  local timeout=600 elapsed=0

  info "Waiting for Ollama init job pod to start..."
  until kubectl get pods -n "$ns" 2>/dev/null | grep -q "ollama-model-loader"; do
    (( elapsed >= timeout )) && warn "Timed out waiting for Ollama init pod — skipping log tail" && return 0
    sleep 5; (( elapsed += 5 ))
    info "  Still waiting for init pod... (${elapsed}s / ${timeout}s)"
  done

  local init_pod
  init_pod=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep "ollama-model-loader" | awk '{print $1}' | head -1)
  [[ -z "$init_pod" ]] && warn "Could not find Ollama init pod — skipping log tail" && return 0

  info "Tailing Ollama init pod logs: $init_pod"
  info "  (This may take several minutes depending on model size and internet speed)"
  echo ""

  # Wait for pod to be running or completed before tailing
  until kubectl get pod "$init_pod" -n "$ns" 2>/dev/null | grep -qE "Running|Completed|Error"; do
    sleep 3
  done

  kubectl logs -f "$init_pod" -n "$ns" 2>/dev/null || \
    warn "Log stream ended — init pod may have completed"

  echo ""
  info "Waiting for Ollama init job to complete..."
  kubectl wait --for=condition=complete job \
    -l "app.kubernetes.io/instance=ollama" \
    -n "$ns" \
    --timeout=600s 2>/dev/null || \
    warn "Init job did not complete within timeout — check: kubectl get pods -n $ns"
}

install_helm_charts() {
  step "Installing Helm charts"
  for i in "${!HELM_NAMES[@]}"; do
    local name="${HELM_NAMES[$i]}"
    local chart="${HELM_CHARTS[$i]}"
    local ns="${HELM_NAMESPACES[$i]}"
    if helm status "$name" -n "$ns" &>/dev/null; then
      warn "Helm release '$name' already exists in '$ns' — skipping"
    else
      info "Installing '$name' from $chart into namespace '$ns'..."
      helm install "$name" "$chart" -n "$ns" &
      local helm_pid=$!
      # Tail init job logs for ollama so the user can see model download progress
      if [[ "$name" == "ollama" ]]; then
        tail_ollama_init_logs "$ns"
      fi
      wait "$helm_pid" || error "Helm install failed for '$name'"
      success "Helm release '$name' installed"
    fi
  done
}

# =============================================================================
# 9. SUMMARY
# =============================================================================
print_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}============================================${RESET}"
  echo -e "${GREEN}${BOLD}  Setup complete!${RESET}"
  echo -e "${GREEN}${BOLD}============================================${RESET}"
  echo ""
  echo -e "  ${BOLD}Podman machine:${RESET}  $MACHINE_NAME"
  echo -e "  ${BOLD}Kind cluster:${RESET}    $KIND_CLUSTER_NAME"
  echo -e "  ${BOLD}Ollama image:${RESET}    $OLLAMA_IMAGE"
  echo -e "  ${BOLD}Namespaces:${RESET}      ${NAMESPACES[*]}"
  echo -e "  ${BOLD}Helm releases:${RESET}"
  for i in "${!HELM_NAMES[@]}"; do
    echo -e "    • ${HELM_NAMES[$i]} → ${HELM_NAMESPACES[$i]}"
  done
  echo ""
  echo -e "  ${CYAN}kubectl get pods -A${RESET}   — check all pods"
  echo -e "  ${CYAN}helm list -A${RESET}          — check Helm releases"
  echo ""
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  echo -e "${BOLD}"
  echo "  ╔═══════════════════════════════════════╗"
  echo "  ║   macOS GPU Stack Setup               ║"
  echo "  ║   Podman + krunkit + kind + helm      ║"
  echo "  ╚═══════════════════════════════════════╝"
  echo -e "${RESET}"

  load_config
  check_prerequisites
  install_tools
  setup_podman_machine
  setup_kind_cluster
  build_and_load_ollama_image
  create_namespaces
  install_helm_charts
  print_summary
}

main "$@"
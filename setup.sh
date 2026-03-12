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
  port=$(podman machine inspect "$MACHINE_NAME"    --format '{{.SSHConfig.Port}}')
  ssh -i "$ssh_key" -p "$port" \
      -o StrictHostKeyChecking=no \
      -o LogLevel=ERROR \
      "root@localhost" "$@"
}

# =============================================================================
# 1. CONFIG LOADING
# =============================================================================

# get_yaml_value FILE SECTION KEY
get_yaml_value() {
  local file="$1" section="$2" key="$3"
  awk -v section="$section" -v key="$key" '
    $0 ~ "^"section":"          { in_section=1; next }
    in_section && /^[a-zA-Z]/  { in_section=0 }
    in_section && $0 ~ "^[[:space:]]+"key":" {
      sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
      gsub(/"/, "")
      print; exit
    }
  ' "$file"
}

# get_yaml_list FILE TOP_KEY
get_yaml_list() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^"key":"              { found=1; next }
    found && /^[a-zA-Z]/       { exit }
    found && /^[[:space:]]*-[[:space:]]/ {
      sub(/^[[:space:]]*-[[:space:]]*/, "")
      gsub(/"/, "")
      print
    }
  ' "$file"
}

# load_helm_releases FILE
load_helm_releases() {
  local file="$1"
  HELM_NAMES=(); HELM_CHARTS=(); HELM_NAMESPACES=()

  local parsed
  parsed=$(awk '
    /^helm:/        { in_helm=1; next }
    in_helm && /^[a-zA-Z]/ && !/^[[:space:]]/ { in_helm=0; in_rel=0; next }
    in_helm && /releases:/ { in_rel=1; next }
    in_rel && /^[[:space:]]+-[[:space:]]*$/ {
      if (name != "") print name "|" chart "|" ns
      name=""; chart=""; ns=""
      next
    }
    in_rel && /^[[:space:]]+-[[:space:]]+name:/ {
      if (name != "") print name "|" chart "|" ns
      name=""; chart=""; ns=""
      sub(/.*name:[[:space:]]*/, ""); gsub(/"/, ""); name=$0; next
    }
    in_rel && /^[[:space:]]+name:/ {
      sub(/.*name:[[:space:]]*/, ""); gsub(/"/, ""); name=$0; next
    }
    in_rel && /^[[:space:]]+-[[:space:]]+chart:/ {
      sub(/.*chart:[[:space:]]*/, ""); gsub(/"/, ""); chart=$0; next
    }
    in_rel && /^[[:space:]]+chart:/ {
      sub(/.*chart:[[:space:]]*/, ""); gsub(/"/, ""); chart=$0; next
    }
    in_rel && /^[[:space:]]+-[[:space:]]+namespace:/ {
      sub(/.*namespace:[[:space:]]*/, ""); gsub(/"/, ""); ns=$0; next
    }
    in_rel && /^[[:space:]]+namespace:/ {
      sub(/.*namespace:[[:space:]]*/, ""); gsub(/"/, ""); ns=$0; next
    }
    END { if (name != "") print name "|" chart "|" ns }
  ' "$file")

  while IFS='|' read -r name chart ns; do
    [[ -z "$name" ]] && continue
    HELM_NAMES+=("$name")
    HELM_CHARTS+=("$SCRIPT_DIR/$chart")
    HELM_NAMESPACES+=("$ns")
  done <<< "$parsed"

  for i in "${!HELM_NAMES[@]}"; do
    info "  Helm release parsed: name=${HELM_NAMES[$i]} ns=${HELM_NAMESPACES[$i]} chart=${HELM_CHARTS[$i]}"
  done
}

# prompt_backends
prompt_backends() {
  echo ""
  echo -e "${BOLD}  Which inference backend would you like to install?${RESET}"
  echo -e "  ${CYAN}1)${RESET} llama.cpp  ${CYAN}[default]${RESET}"
  echo -e "  ${CYAN}2)${RESET} Ollama"
  echo ""
  read -r -p "  Enter choice [1]: " choice
  choice="${choice:-1}"

  case "$choice" in
    1)
      ENABLED_BACKENDS=("llamacpp")
      info "Installing: llama.cpp"
      ;;
    2)
      ENABLED_BACKENDS=("ollama")
      info "Installing: Ollama"
      ;;
    *)
      warn "Invalid choice '$choice' — defaulting to llama.cpp"
      ENABLED_BACKENDS=("llamacpp")
      ;;
  esac
  echo ""
}

backend_enabled() {
  local target="$1"
  for b in "${ENABLED_BACKENDS[@]}"; do
    [[ "$b" == "$target" ]] && return 0
  done
  return 1
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || error "Config file not found at: $CONFIG_FILE"
  info "Loading config from: $CONFIG_FILE"

  MACHINE_NAME=$(get_yaml_value "$CONFIG_FILE" "podman"  "machine_name")
  MACHINE_CPU=$( get_yaml_value "$CONFIG_FILE" "podman"  "cpu")
  MACHINE_MEM=$( get_yaml_value "$CONFIG_FILE" "podman"  "memory")
  MACHINE_DISK=$(get_yaml_value "$CONFIG_FILE" "podman"  "disk")

  KIND_CONFIG="$SCRIPT_DIR/$(get_yaml_value "$CONFIG_FILE" "paths" "kind_config")"

  KIND_CLUSTER_NAME=$(get_yaml_value "$CONFIG_FILE" "kind"    "cluster_name")
  KRUNKIT_TAP=$(      get_yaml_value "$CONFIG_FILE" "krunkit" "brew_tap")
  KRUNKIT_PKG=$(      get_yaml_value "$CONFIG_FILE" "krunkit" "brew_pkg")

  OLLAMA_IMAGE=$(get_yaml_value "$CONFIG_FILE" "ollama" "image")
  OLLAMA_DOCKERFILE="$SCRIPT_DIR/$(get_yaml_value "$CONFIG_FILE" "paths" "ollama_dockerfile")"

  LLAMACPP_IMAGE=$(get_yaml_value "$CONFIG_FILE" "llamacpp" "image")
  LLAMACPP_DOCKERFILE="$SCRIPT_DIR/$(get_yaml_value "$CONFIG_FILE" "paths" "llamacpp_dockerfile")"

  NAMESPACES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && NAMESPACES+=("$line")
  done < <(get_yaml_list "$CONFIG_FILE" "namespaces")

  load_helm_releases "$CONFIG_FILE"

  local missing=()
  [[ -z "$MACHINE_NAME"        ]] && missing+=("podman.machine_name")
  [[ -z "$MACHINE_CPU"         ]] && missing+=("podman.cpu")
  [[ -z "$MACHINE_MEM"         ]] && missing+=("podman.memory")
  [[ -z "$MACHINE_DISK"        ]] && missing+=("podman.disk")
  [[ -z "$KIND_CLUSTER_NAME"   ]] && missing+=("kind.cluster_name")
  [[ -z "$OLLAMA_IMAGE"        ]] && missing+=("ollama.image")
  [[ -z "$OLLAMA_DOCKERFILE"   ]] && missing+=("paths.ollama_dockerfile")
  [[ -z "$LLAMACPP_IMAGE"      ]] && missing+=("llamacpp.image")
  [[ -z "$LLAMACPP_DOCKERFILE" ]] && missing+=("paths.llamacpp_dockerfile")
  [[ ${#missing[@]} -gt 0 ]] && error "Config missing required fields: ${missing[*]}"

  success "Config loaded"
  info "  Machine:    $MACHINE_NAME (${MACHINE_CPU} cpu, ${MACHINE_MEM}MB, ${MACHINE_DISK}GB)"
  info "  Cluster:    $KIND_CLUSTER_NAME"
  info "  Namespaces: ${NAMESPACES[*]}"
  info "  Helm:       ${HELM_NAMES[*]}"
  [[ -n "$OLLAMA_IMAGE"   ]] && info "  Ollama:     $OLLAMA_IMAGE"
  [[ -n "$LLAMACPP_IMAGE" ]] && info "  llama.cpp:  $LLAMACPP_IMAGE ($LLAMACPP_DOCKERFILE)"
}

# =============================================================================
# 2. PREREQUISITE CHECKS
# =============================================================================
check_prerequisites() {
  step "Checking prerequisites"
  command -v brew &>/dev/null || error "Homebrew not found. Install from https://brew.sh"
  success "Homebrew found"

  [[ -f "$KIND_CONFIG" ]] || error "kind config not found at $KIND_CONFIG"
  success "kind config found: $KIND_CONFIG"

  if backend_enabled "ollama"; then
    [[ -f "$OLLAMA_DOCKERFILE" ]] || error "Ollama Dockerfile not found at $OLLAMA_DOCKERFILE"
    success "Ollama Dockerfile found: $OLLAMA_DOCKERFILE"
  fi

  if backend_enabled "llamacpp"; then
    [[ -f "$LLAMACPP_DOCKERFILE" ]] || \
      error "llama.cpp Dockerfile not found at $LLAMACPP_DOCKERFILE"
    success "llama.cpp Dockerfile found: $LLAMACPP_DOCKERFILE"
  fi

  for i in "${!HELM_NAMES[@]}"; do
    local name="${HELM_NAMES[$i]}"
    if [[ "$name" == "ollama"   ]] && ! backend_enabled "ollama";   then continue; fi
    if [[ "$name" == "llamacpp" ]] && ! backend_enabled "llamacpp"; then continue; fi
    [[ -d "${HELM_CHARTS[$i]}" ]] || \
      error "Helm chart '$name' not found at ${HELM_CHARTS[$i]}"
    success "Helm chart found: $name → ${HELM_CHARTS[$i]}"
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

  if command -v krunkit &>/dev/null; then
    warn "krunkit already installed — skipping"
  else
    info "Installing krunkit via brew tap $KRUNKIT_TAP..."
    brew tap "$KRUNKIT_TAP"
    brew install "$KRUNKIT_PKG"
    success "krunkit installed"
  fi

  install_brew_pkg "podman"
  install_brew_pkg "podman-desktop" "podman-desktop" "cask"
  install_brew_pkg "kind"
  install_brew_pkg "helm"
}

# =============================================================================
# 4. PODMAN MACHINE
# =============================================================================
setup_podman_machine() {
  step "Setting up Podman machine"

  if podman machine list --format '{{.Name}}' 2>/dev/null | sed 's/\*$//' | grep -q "^${MACHINE_NAME}$"; then
    local config_dir
    config_dir=$(podman machine inspect "$MACHINE_NAME" 2>/dev/null \
      | grep -i '"Path"' | head -1 | tr -d ' ",' | cut -d: -f2)
    if echo "$config_dir" | grep -q "applehv"; then
      error "Podman machine '$MACHINE_NAME' uses applehv (no GPU passthrough). Remove it and re-run:
       podman machine stop $MACHINE_NAME && podman machine rm $MACHINE_NAME
       /opt/homebrew/bin/bash setup.sh"
    fi
    warn "Podman machine '$MACHINE_NAME' already exists — skipping init"
  else
    local containers_conf="$HOME/.config/containers/containers.conf"
    if [[ ! -f "$containers_conf" ]] || ! grep -q "provider.*libkrun" "$containers_conf"; then
      info "Configuring Podman to use libkrun provider..."
      mkdir -p "$(dirname "$containers_conf")"
      cat > "$containers_conf" << 'EOF'
[machine]
provider = "libkrun"
EOF
      success "Podman provider set to libkrun"
    fi

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

  info "Setting rootful connection as default..."
  podman system connection default "${MACHINE_NAME}-root" 2>/dev/null || \
    error "Could not set rootful connection '${MACHINE_NAME}-root'. Run: podman system connection list"

  local rootless
  rootless=$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || echo "unknown")
  [[ "$rootless" == "false" ]] || \
    error "Podman is still running rootless. Check: podman system connection list"
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
# 6. BUILD AND LOAD IMAGES
# =============================================================================

build_and_load_image() {
  local image="$1" dockerfile="$2" label="$3"
  local image_name="${image%%:*}"
  local image_tag="${image##*:}"
  local vm_tar="/root/tmp/${image_name}-${image_tag}.tar"
  local vm_build_dir="/root/tmp/${image_name}-build"

  vm_ssh "mkdir -p /root/tmp"

  local already_loaded
  already_loaded=$(vm_ssh "podman exec ${KIND_CLUSTER_NAME}-control-plane \
    crictl images 2>/dev/null | grep -c '${image_name}'" || echo "0")
  if [[ "${already_loaded:-0}" -gt 0 ]]; then
    warn "Image '$image' already loaded in kind — skipping ($label)"
    return 0
  fi

  [[ -f "$dockerfile" ]] || error "$label Dockerfile not found at $dockerfile"

  local build_context
  build_context="$(dirname "$dockerfile")"

  info "Copying $label build context into VM ($build_context)..."
  vm_ssh "mkdir -p $vm_build_dir"
  tar -C "$build_context" -cf - . | \
    vm_ssh "tar -C $vm_build_dir -xf -"
  success "$label build context copied to VM"

  info "Building '$image' inside VM ($label) — this may take 10-20 minutes..."
  vm_ssh "podman build --device /dev/dri \
    -f ${vm_build_dir}/$(basename "$dockerfile") \
    -t ${image} \
    ${vm_build_dir}" || error "Failed to build $label image"
  success "Image '$image' built ($label)"

  info "Saving $label image to tar inside VM..."
  vm_ssh "podman save -o ${vm_tar} ${image}" || error "Failed to save $label image"
  success "$label image saved to ${vm_tar} inside VM"

  info "Loading $label image into kind cluster..."
  vm_ssh "podman cp ${vm_tar} ${KIND_CLUSTER_NAME}-control-plane:/tmp/ && \
    podman exec ${KIND_CLUSTER_NAME}-control-plane \
      ctr -n k8s.io images import /tmp/$(basename "${vm_tar}") && \
    podman exec ${KIND_CLUSTER_NAME}-control-plane \
      rm -f /tmp/$(basename "${vm_tar}")" || error "Failed to load $label image into kind"
  success "Image '$image' loaded into kind cluster ($label)"

  vm_ssh "rm -f ${vm_tar}"
}

build_and_load_ollama_image() {
  step "Building and loading Ollama image"
  build_and_load_image "$OLLAMA_IMAGE" "$OLLAMA_DOCKERFILE" "Ollama"
}

build_and_load_llamacpp_image() {
  step "Building and loading llama.cpp image"
  build_and_load_image "$LLAMACPP_IMAGE" "$LLAMACPP_DOCKERFILE" "llama.cpp"
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

tail_init_logs() {
  local ns="$1" pod_prefix="$2" label="$3"
  local timeout=3600 elapsed=0

  info "Waiting for $label init job pod to start..."
  until kubectl get pods -n "$ns" 2>/dev/null | grep -q "$pod_prefix"; do
    (( elapsed >= timeout )) && \
      warn "Timed out waiting for $label init pod — skipping log tail" && return 0
    sleep 5; (( elapsed += 5 ))
    info "  Still waiting for $label init pod... (${elapsed}s / ${timeout}s)"
  done

  local init_pod
  init_pod=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
    | grep "$pod_prefix" | awk '{print $1}' | head -1)
  [[ -z "$init_pod" ]] && \
    warn "Could not find $label init pod — skipping log tail" && return 0

  info "Tailing $label init pod logs: $init_pod"
  info "  (This may take several minutes depending on model size and internet speed)"
  echo ""

  until kubectl get pod "$init_pod" -n "$ns" 2>/dev/null | grep -qE "Running|Completed|Error|Succeeded"; do
    sleep 3
  done

  kubectl logs -f "$init_pod" -n "$ns" 2>/dev/null || true

  echo ""
  success "$label init job completed"
}

install_helm_charts() {
  step "Installing Helm charts"
  for i in "${!HELM_NAMES[@]}"; do
    local name="${HELM_NAMES[$i]}"
    local chart="${HELM_CHARTS[$i]}"
    local ns="${HELM_NAMESPACES[$i]}"

    if [[ "$name" == "ollama"   ]] && ! backend_enabled "ollama";   then
      info "Skipping Helm release '$name' — ollama not selected"
      continue
    fi
    if [[ "$name" == "llamacpp" ]] && ! backend_enabled "llamacpp"; then
      info "Skipping Helm release '$name' — llamacpp not selected"
      continue
    fi

    if helm status "$name" -n "$ns" &>/dev/null; then
      warn "Helm release '$name' already exists in '$ns' — skipping install"
      case "$name" in
        ollama|llamacpp) restart_and_verify ;;
      esac
      continue
    fi

    info "Installing '$name' from $chart into namespace '$ns'..."
    helm install "$name" "$chart" -n "$ns" --timeout 3h \
      2>"/tmp/helm_err_${name}" &
    local helm_pid=$!

    sleep 5
    if ! kill -0 "$helm_pid" 2>/dev/null; then
      local helm_exit=0
      wait "$helm_pid" || helm_exit=$?
      if [[ $helm_exit -ne 0 ]]; then
        error "Helm install failed for '$name': $(cat /tmp/helm_err_${name} 2>/dev/null)"
      fi
      rm -f "/tmp/helm_err_${name}"
      success "Helm release '$name' installed"
    else
      case "$name" in
        ollama)   tail_init_logs "$ns" "ollama-model-loader"   "Ollama" ;;
        llamacpp) tail_init_logs "$ns" "llamacpp-model-loader" "llama.cpp" ;;
      esac

      local helm_exit=0
      set +e
      wait "$helm_pid" 2>/dev/null
      helm_exit=$?
      set -e
      if [[ $helm_exit -ne 0 && $helm_exit -ne 127 ]]; then
        error "Helm install failed for '$name': $(cat /tmp/helm_err_${name} 2>/dev/null)"
      fi
      rm -f "/tmp/helm_err_${name}"
      success "Helm release '$name' installed"
    fi

    case "$name" in
      ollama|llamacpp) restart_and_verify ;;
    esac
  done
}

# =============================================================================
# 9. WAIT FOR BACKEND DEPLOYMENT
# =============================================================================

# wait_for_backend_deployment BACKEND
# Waits for:
#   1. The deployment object to exist
#   2. The rollout to complete (all replicas ready)
#   3. The pod to be in Running state
#   4. The /health endpoint to respond (handles slow device discovery / weight loading)
wait_for_backend_deployment() {
  local backend="$1"
  local ns="$backend"
  local timeout=300 elapsed=0

  step "Waiting for $backend deployment to be fully ready"

  # 1. Wait for the deployment object to appear
  info "Waiting for $backend deployment object..."
  elapsed=0
  until kubectl get deployment "$backend" -n "$ns" &>/dev/null 2>&1; do
    (( elapsed >= timeout )) && error "Timed out waiting for $backend deployment to appear"
    sleep 5; (( elapsed += 5 ))
    info "  Still waiting for deployment object... (${elapsed}s / ${timeout}s)"
  done
  success "$backend deployment object found"

  # 2. Wait for rollout (all replicas scheduled and ready)
  info "Waiting for $backend rollout to complete..."
  kubectl rollout status deployment/"$backend" -n "$ns" --timeout="${timeout}s" || \
    error "$backend rollout failed — check: kubectl describe deployment/$backend -n $ns"
  success "$backend rollout complete"

  # 3. Wait for at least one pod to reach Running
  info "Waiting for $backend pod to reach Running state..."
  elapsed=0
  until kubectl get pods -n "$ns" --no-headers 2>/dev/null \
      | grep -E "^$backend-" | awk '{print $3}' | grep -q "^Running$"; do
    (( elapsed >= timeout )) && error "Timed out waiting for $backend pod to reach Running"
    sleep 5; (( elapsed += 5 ))
    # Print current pod status on each poll so the user can see progress
    local pod_status
    pod_status=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null \
      | grep -E "^$backend-" | awk '{print $1, $3, $4}' || echo "  (no pods yet)")
    info "  Pod status: $pod_status (${elapsed}s / ${timeout}s)"
  done
  success "$backend pod is Running"

  # 4. Wait for /health endpoint — the process may be up but still loading
  #    model weights or discovering GPU devices before it starts serving.
  local svc_port
  case "$backend" in
    llamacpp) svc_port=30480 ;;
    ollama)   svc_port=30434 ;;
    *)
      warn "Unknown backend '$backend' — skipping /health check"
      return 0
      ;;
  esac

  info "Waiting for $backend /health on http://localhost:${svc_port}/health ..."
  info "  (llama.cpp loads weights and discovers GPU devices before serving)"
  elapsed=0
  until curl -sf --max-time 5 "http://localhost:${svc_port}/health" &>/dev/null; do
    if (( elapsed >= timeout )); then
      warn "Timed out waiting for $backend /health after ${timeout}s — it may still be initializing"
      warn "  Check manually: curl http://localhost:${svc_port}/health"
      return 0
    fi
    sleep 5; (( elapsed += 5 ))
    info "  Still waiting for /health... (${elapsed}s / ${timeout}s)"
  done
  success "$backend /health OK on port $svc_port"
}

# =============================================================================
# 10. RESTART AND VERIFY
# =============================================================================
restart_and_verify() {
  step "Restarting Podman machine and cluster"

  info "Stopping Podman machine..."
  podman machine stop "$MACHINE_NAME"

  info "Starting Podman machine..."
  podman machine start "$MACHINE_NAME" || warn "machine start returned non-zero — checking connectivity anyway"

  info "Setting rootful connection as default..."
  podman system connection default "${MACHINE_NAME}-root"

  info "Waiting for Podman machine to be ready..."
  local timeout=180 elapsed=0
  until podman info &>/dev/null 2>&1; do
    (( elapsed >= timeout )) && error "Timed out waiting for Podman machine after restart"
    sleep 5; (( elapsed += 5 ))
    info "  Still waiting... (${elapsed}s / ${timeout}s)"
  done
  success "Podman machine is ready"

  info "Starting kind control plane node..."
  vm_ssh "podman start ${KIND_CLUSTER_NAME}-control-plane" || \
    warn "Could not start control plane container — it may already be running"

  info "Refreshing kubeconfig..."
  local podman_sock
  podman_sock=$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)
  export DOCKER_HOST="unix://${podman_sock}"
  export KIND_EXPERIMENTAL_PROVIDER=podman
  kind export kubeconfig --name "$KIND_CLUSTER_NAME"

  info "Waiting for cluster node to be Ready..."
  local timeout=120 elapsed=0
  until kubectl get nodes 2>/dev/null | grep -q " Ready"; do
    (( elapsed >= timeout )) && error "Timed out waiting for cluster node after restart"
    sleep 5; (( elapsed += 5 ))
    info "  Still waiting... (${elapsed}s / ${timeout}s)"
  done
  success "Cluster node is Ready"

  # Wait for any enabled backend deployments that already exist (i.e. Helm has
  # already deployed them in a prior iteration) to come back healthy after the
  # Podman/kind restart.  The guard on kubectl get deployment means this is a
  # no-op on the very first restart (before Helm has run for that backend).
  for backend in "llamacpp" "ollama"; do
    if backend_enabled "$backend"; then
      if kubectl get deployment "$backend" -n "$backend" &>/dev/null 2>&1; then
        wait_for_backend_deployment "$backend"
      fi
    fi
  done
}

# =============================================================================
# 11. SUMMARY
# =============================================================================
print_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}============================================${RESET}"
  echo -e "${GREEN}${BOLD}  Setup complete!${RESET}"
  echo -e "${GREEN}${BOLD}============================================${RESET}"
  echo ""
  echo -e "  ${BOLD}Podman machine:${RESET}  $MACHINE_NAME"
  echo -e "  ${BOLD}Kind cluster:${RESET}    $KIND_CLUSTER_NAME"
  backend_enabled "ollama"   && echo -e "  ${BOLD}Ollama image:${RESET}    $OLLAMA_IMAGE"
  backend_enabled "llamacpp" && echo -e "  ${BOLD}llama.cpp image:${RESET} $LLAMACPP_IMAGE"
  echo -e "  ${BOLD}Namespaces:${RESET}      ${NAMESPACES[*]}"
  echo -e "  ${BOLD}Helm releases:${RESET}"
  for i in "${!HELM_NAMES[@]}"; do
    echo -e "    • ${HELM_NAMES[$i]} → ${HELM_NAMESPACES[$i]}"
  done
  echo ""
  echo -e "  ${CYAN}Endpoints:${RESET}"
  backend_enabled "ollama"   && echo -e "    Ollama:     http://localhost:30434"
  backend_enabled "llamacpp" && echo -e "    llama.cpp:  http://localhost:30480"
  echo -e "    n8n:        http://localhost:30678"
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
  prompt_backends
  check_prerequisites
  install_tools
  setup_podman_machine
  setup_kind_cluster
  backend_enabled "ollama"   && build_and_load_ollama_image
  backend_enabled "llamacpp" && build_and_load_llamacpp_image
  create_namespaces
  install_helm_charts
  print_summary
}

main "$@"
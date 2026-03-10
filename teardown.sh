#!/opt/homebrew/bin/bash
# =============================================================================
# teardown.sh — Completely uninstall the macOS GPU AI stack
# =============================================================================
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "ERROR: bash 4+ required. Install with: brew install bash" >&2
  echo "       Then run with: /opt/homebrew/bin/bash teardown.sh" >&2
  exit 1
fi

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
step()    { echo -e "\n${BOLD}==> $*${RESET}"; }

# =============================================================================
# CONFIRM
# =============================================================================
echo -e "${RED}${BOLD}"
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║   macOS GPU AI Stack — TEARDOWN               ║"
echo "  ║   This will remove ALL stack components       ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "${YELLOW}This will uninstall:${RESET}"
echo "  • Podman machine and all containers"
echo "  • kind cluster"
echo "  • podman, podman-desktop, kind, helm, krunkit"
echo "  • All Podman config and data directories"
echo ""
read -r -p "Are you sure? (yes/no): " confirm
[[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 0; }

# =============================================================================
# 1. STOP AND REMOVE PODMAN MACHINES
# =============================================================================
step "Stopping and removing Podman machines"
podman machine stop --all 2>/dev/null && success "All machines stopped" || warn "No machines to stop"
podman machine rm --all -f 2>/dev/null && success "All machines removed" || warn "No machines to remove"

# =============================================================================
# 2. KILL STRAY PROCESSES
# =============================================================================
step "Killing stray processes"
pkill -f gvproxy 2>/dev/null && success "gvproxy killed" || warn "gvproxy not running"
pkill -f krunkit 2>/dev/null && success "krunkit killed" || warn "krunkit not running"

# =============================================================================
# 3. UNINSTALL BREW PACKAGES
# =============================================================================
step "Uninstalling brew packages"

uninstall_brew() {
  local pkg="$1"
  if brew list "$pkg" &>/dev/null; then
    brew uninstall --force "$pkg" && success "$pkg uninstalled"
  else
    warn "$pkg not installed — skipping"
  fi
}

uninstall_brew "kind"
uninstall_brew "helm"
uninstall_brew "slp/krunkit/krunkit"
uninstall_brew "slp/krunkit/libkrun-efi"
uninstall_brew "podman"

if brew list --cask podman-desktop &>/dev/null; then
  brew uninstall --cask --force podman-desktop && success "podman-desktop uninstalled"
else
  warn "podman-desktop not installed — skipping"
fi

brew untap slp/krunkit 2>/dev/null && success "slp/krunkit tap removed" || warn "slp/krunkit tap not found"

# =============================================================================
# 4. REMOVE CONFIG AND DATA DIRECTORIES
# =============================================================================
step "Removing Podman config and data directories"

remove_dir() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    rm -rf "$dir" && success "Removed $dir"
  else
    warn "$dir not found — skipping"
  fi
}

remove_dir "$HOME/.config/containers"
remove_dir "$HOME/.local/share/containers"
remove_dir "$HOME/.cache/containers"

# Clean up any stray podman temp files
sudo rm -rf /private/var/tmp/podman* 2>/dev/null && success "Removed stray podman tmp files" || true
rm -rf /tmp/podman* 2>/dev/null || true

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}============================================${RESET}"
echo -e "${GREEN}${BOLD}  Teardown complete!${RESET}"
echo -e "${GREEN}${BOLD}============================================${RESET}"
echo ""
echo -e "  To reinstall, run: ${CYAN}/opt/homebrew/bin/bash setup.sh${RESET}"
echo ""
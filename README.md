# macos-gpu-ai-stack
### Kubernetes on Podman with GPU-accelerated Ollama and n8n

This stack runs a local Kubernetes cluster on macOS using Podman with GPU passthrough via krunkit/libkrun-efi, giving Ollama access to the host's Metal GPU instead of falling back to CPU inference.

**Stack overview:**
- **Podman** — container engine (replaces Docker)
- **krunkit + libkrun-efi** — hypervisor that enables GPU passthrough from macOS to the VM
- **kind** — Kubernetes cluster running inside the Podman VM
- **Ollama** — LLM inference server with Vulkan/GPU acceleration
- **n8n** — workflow automation platform

---

## Prerequisites

### Hardware
- Apple Silicon Mac (M1 or later)
- macOS Sequoia 15.0 or later
- 16GB RAM minimum (24GB+ recommended)

### Software
Install Homebrew if not already installed:
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Install Bash 4+ (macOS ships with Bash 3):
```bash
brew install bash
```

---

## Installation

### 1. Clone the repository
```bash
git clone <your-repo-url>
cd <your-repo>
```

### 2. Review config.yaml
Adjust resources to match your machine. Recommended starting point:

```yaml
podman:
  machine_name: podman-machine-default
  cpu: 8
  memory: 16384       # 16GB — reduce if you experience VM instability
  disk: 100

krunkit:
  brew_tap: slp/krunkit
  brew_pkg: slp/krunkit/krunkit

kind:
  cluster_name: ai-cluster

ollama:
  image: fedora-ollama-vulkan:v1

namespaces:
  - ollama
  - n8n

paths:
  kind_config: kind-config.yaml
  ollama_dockerfile: Dockerfile.ollama

helm:
  - name: ollama
    chart: charts/ollama
    namespace: ollama
  - name: n8n
    chart: charts/n8n
    namespace: n8n
```

> **Note on memory:** libkrun-efi can crash the VM under heavy memory pressure. If you experience instability, reduce `memory` in `config.yaml` and recreate the machine. 16384 (16GB) is a stable value on a 36GB host.

### 3. Review kind-config.yaml
Port mappings are set at cluster creation time and cannot be changed without recreating the cluster. Add all ports you need upfront:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ai-cluster
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: /dev/dri
        containerPath: /dev/dri
        propagation: HostToContainer
    extraPortMappings:
      - containerPort: 30678    # n8n NodePort
        hostPort: 30678
        protocol: TCP
      - containerPort: 30080    # HTTP ingress
        hostPort: 8080
        protocol: TCP
      - containerPort: 30443    # HTTPS ingress
        hostPort: 8443
        protocol: TCP
```

### 4. Run the setup script
```bash
/opt/homebrew/bin/bash setup.sh
```

The script will:
1. Install Podman, kind, helm, krunkit, and libkrun-efi via Homebrew
2. Create and start the Podman VM with GPU passthrough enabled
3. Set the rootful Podman connection as default
4. Create the kind Kubernetes cluster
5. Build and load the Ollama image into the cluster
6. Create Kubernetes namespaces
7. Install Helm charts

> The first run takes 10–20 minutes depending on your internet connection. Subsequent runs skip already-completed steps.

---

## Post-Installation

### Set environment variables permanently
kind and Docker tooling need to know to use Podman instead of Docker. Add these to your shell profile:

```bash
# For zsh (default on macOS)
echo '' >> ~/.zshrc
echo '# Podman/kind configuration' >> ~/.zshrc
echo 'export KIND_EXPERIMENTAL_PROVIDER=podman' >> ~/.zshrc
echo 'export DOCKER_HOST="unix://$(podman info --format '\''{{.Host.RemoteSocket.Path}}'\'' 2>/dev/null)"' >> ~/.zshrc
source ~/.zshrc
```

```bash
# For bash
echo '' >> ~/.bash_profile
echo '# Podman/kind configuration' >> ~/.bash_profile
echo 'export KIND_EXPERIMENTAL_PROVIDER=podman' >> ~/.bash_profile
echo 'export DOCKER_HOST="unix://$(podman info --format '\''{{.Host.RemoteSocket.Path}}'\'' 2>/dev/null)"' >> ~/.bash_profile
source ~/.bash_profile
```

> **Note:** `DOCKER_HOST` is evaluated at shell startup so it always picks up the current Podman socket path, which can change when the machine restarts.

### Verify the installation
```bash
# Check Podman is rootful
podman info --format '{{.Host.Security.Rootless}}'   # must be: false

# Check cluster is running
kubectl get nodes
kubectl get pods -A

# Check Helm releases
helm list -A
```

---

## Day-to-Day Operations

### Starting after a reboot
The Podman machine and kind cluster do not start automatically after a reboot:
```bash
podman machine start podman-machine-default
podman system connection default podman-machine-default-root
kind export kubeconfig --name ai-cluster
kubectl get nodes
```

### Stopping everything
```bash
kubectl delete --all pods -A 2>/dev/null || true
podman machine stop podman-machine-default
```

---

## Updating the Ollama Image

The Ollama image is built from source inside the Podman VM with Vulkan patches applied for krunkit/virtio-gpu compatibility. When a new version of Ollama is released, the image needs to be rebuilt and reloaded into the kind cluster.

### 1. Check the current Ollama version
```bash
kubectl exec -it <ollama-pod-name> -n ollama -- ollama --version
```

### 2. Rebuild the image
The Dockerfile clones `ollama/ollama` from GitHub at build time, so rebuilding automatically pulls the latest version:
```bash
# Remove the existing image from the VM so the script rebuilds it
podman machine ssh podman-machine-default -- podman rmi fedora-ollama-vulkan:v1 2>/dev/null || true

# Remove from the kind node so it gets reloaded
podman machine ssh podman-machine-default -- \
  podman exec ai-cluster-control-plane \
  ctr -n k8s.io images rm docker.io/library/fedora-ollama-vulkan:v1 2>/dev/null || true
```

### 3. Re-run the setup script
The script detects the image is missing and rebuilds and reloads it automatically:
```bash
/opt/homebrew/bin/bash setup.sh
```

### 4. Restart the Ollama deployment to pick up the new image
```bash
kubectl rollout restart deployment/ollama -n ollama
kubectl rollout status deployment/ollama -n ollama
```

### 5. Verify the new version
```bash
kubectl exec -it <ollama-pod-name> -n ollama -- ollama --version
```

> **Note:** The build takes 10–20 minutes as it compiles Ollama from source with Vulkan support. Downloaded models are stored on a persistent volume and are not affected by image rebuilds.

### Pinning a specific Ollama version
To pin to a specific Ollama release instead of always building latest, edit `ollama/macos/Dockerfile` and change the clone line:
```dockerfile
# Replace this:
RUN git clone https://github.com/ollama/ollama.git /ollama

# With this (example for v0.9.0):
RUN git clone --branch v0.9.0 --depth 1 https://github.com/ollama/ollama.git /ollama
```

Then rebuild following steps 2–4 above.

---

## Managing Ollama Models

Models are configured in `helm/ollama/values.yaml` under the `models.pull` list:

```yaml
models:
  pull:
    - llama3.2
    - mistral
    - gpt-oss:20b
```

### Adding or removing models
Edit `helm/ollama/values.yaml` and update the list, then upgrade the Helm release:
```bash
helm upgrade ollama ./helm/ollama -n ollama
```

The `ollama-model-loader` job will run and pull any new models. Already-downloaded models are skipped.

### Pulling from HuggingFace directly
Use the `hf.co/` prefix to pull a model directly from HuggingFace:
```yaml
models:
  pull:
    - hf.co/bartowski/openai_gpt-oss-20b-GGUF:Q4_K_M
```

### Pulling a model manually
```bash
kubectl exec -it <ollama-pod-name> -n ollama -- ollama pull <model-name>

# Examples
kubectl exec -it <ollama-pod-name> -n ollama -- ollama pull llama3.2
kubectl exec -it <ollama-pod-name> -n ollama -- ollama pull hf.co/bartowski/openai_gpt-oss-20b-GGUF:Q4_K_M
```

### Listing downloaded models
```bash
kubectl exec -it <ollama-pod-name> -n ollama -- ollama list
```

### Removing a model
```bash
kubectl exec -it <ollama-pod-name> -n ollama -- ollama rm <model-name>
```

### GPU tuning
GPU and inference settings are also configured in `helm/ollama/values.yaml` under `env`:
```yaml
env:
  OLLAMA_NUM_GPU: "999"       # number of layers to offload to GPU (999 = all)
  OLLAMA_NUM_CTX: "8192"      # context window size
  OLLAMA_NUM_THREAD: "8"      # CPU threads for non-GPU work
  OLLAMA_KEEP_ALIVE: "-1"     # keep model loaded in GPU memory permanently
```

---

## Updating Helm Charts

### Upgrade a single release
```bash
helm upgrade <release-name> <chart-path> -n <namespace>

# Examples
helm upgrade ollama ./charts/ollama -n ollama
helm upgrade n8n ./charts/n8n -n n8n
```

### Upgrade all releases
```bash
helm list -A --short | while read release; do
  namespace=$(helm list -A | grep "^$release" | awk '{print $2}')
  chart=$(helm list -A | grep "^$release" | awk '{print $9}' | sed 's/-[0-9].*//')
  helm upgrade "$release" "./charts/$chart" -n "$namespace"
done
```

### Rollback a release
```bash
helm rollback <release-name> -n <namespace>

# Example
helm rollback ollama -n ollama
```

### Check release history
```bash
helm history <release-name> -n <namespace>
```

---

## Recreating the kind Cluster

You need to recreate the cluster when:
- Adding or removing port mappings
- Changing node configuration
- The cluster becomes unrecoverable

```bash
# Set Podman as the Docker provider first
export DOCKER_HOST="unix://$(podman info --format '{{.Host.RemoteSocket.Path}}')"
export KIND_EXPERIMENTAL_PROVIDER=podman

# Delete the cluster
kind delete cluster --name ai-cluster

# Re-run the setup script — it will recreate the cluster and reinstall Helm charts
/opt/homebrew/bin/bash setup.sh
```

---

## Recreating the Podman Machine

Required when changing CPU/memory/disk in `config.yaml`, or after a krunkit upgrade:

```bash
podman machine stop podman-machine-default
podman machine rm podman-machine-default

# Re-run setup — recreates everything from scratch
/opt/homebrew/bin/bash setup.sh
```

> **Warning:** This destroys the kind cluster and all loaded images. The setup script rebuilds everything automatically, but it will take 10–20 minutes.

---

## GPU Performance Benchmarks

Benchmarks run on a **Mac M3 Pro** using Ollama with Vulkan GPU acceleration via krunkit/libkrun-efi. Results are averages across multiple inference runs.

| Model | Size | Avg Tokens/sec |
|---|---|---|
| llama3.2 | 3B | 49 tok/s |
| mistral | 7B | 26 tok/s |
| gpt-oss:20b | 20B | 27 tok/s |

To measure tokens/sec on your own hardware:
```bash
curl -s http://localhost:30434/api/generate -d '{
  "model": "your-model-name",
  "prompt": "Write a short story about a robot.",
  "stream": false
}' | python3 -c "
import json, sys
d = json.load(sys.stdin)
tps = d['eval_count'] / (d['eval_duration'] / 1e9)
print(f'Tokens/sec: {tps:.1f}')
print(f'Tokens generated: {d[\"eval_count\"]}')
print(f'Time: {d[\"eval_duration\"]/1e9:.2f}s')
"
```

---

## Troubleshooting

### kubectl cannot reach the cluster after reboot
```bash
podman machine start podman-machine-default
podman system connection default podman-machine-default-root
kind export kubeconfig --name ai-cluster
```

### kind delete/get cluster fails with Docker socket error
kind defaults to Docker. Always set the provider first:
```bash
export DOCKER_HOST="unix://$(podman info --format '{{.Host.RemoteSocket.Path}}')"
export KIND_EXPERIMENTAL_PROVIDER=podman
kind get clusters
kind delete cluster --name ai-cluster
```

### Podman machine crashes under load
libkrun-efi 1.16.0 can crash the VM under heavy CPU or memory pressure. Recovery:
```bash
podman machine stop podman-machine-default 2>/dev/null || true
podman machine start podman-machine-default
podman system connection default podman-machine-default-root
kind export kubeconfig --name ai-cluster
kubectl get nodes
```
If crashes are frequent, reduce `memory` in `config.yaml` and recreate the machine.

### Podman is running rootless
```bash
podman system connection default podman-machine-default-root
podman info --format '{{.Host.Security.Rootless}}'   # must be: false
```

### Check krunkit/VM logs
```bash
log show --predicate 'process == "krunkit"' --last 30m | grep -i error
```
# K9s Cluster Manager (macOS)

macOS tool to switch Kubernetes clusters and open **k9s quickly.

---

## Requirements

- Internet access (for first run)
- Kubernetes cluster YAML files

---

### 1. Download the Tool

git clone https://github.com/jfebrada-cap/k9s-switcher.git
cd k9s-switcher

### 2. Make It Executable
chmod +x k9s_cluster_manager.sh

### 3. Run It

./k9s_cluster_manager.sh

On the first run, the script will automatically install everything it needs
(kubectl, k9s, Python, etc.).
You do not need to install anything manually.

---

## Where to Put Your kubeconfig manifest

Place your Kubernetes YAML files in the `YAML/` folder.

YAML/
├── prd/        # Production clusters
├── nprd/       # Non-production clusters

The script will also work if YAML files are directly under `YAML/`.

---

## Using the Menu

When the tool starts, you will see a list of clusters grouped by environment.

### Controls

| Key   | Action                 |
| ----- | ---------------------- |
| `1–N` | Select a cluster       |
| `f`   | Find a cluster by name |
| `r`   | Refresh the list       |
| `q`   | Quit                   |

Clusters are shown in **two columns** to make scanning easier.

---

## Finding a Cluster

1. Press `f`
2. Type part of the cluster name
3. Select the number shown

Example:

Enter cluster name: cards

---

## Switching Clusters

When you select a cluster:

1. Your kubeconfig is switched
2. The connection is checked
3. **k9s opens automatically**

Inside k9s:

```
Press 0 to return to the menu
```

---

## Built-In Actions

* Clusters are grouped (PRD, SIT, UAT, TEST, etc.)
* Broken certificates are cleaned automatically
* Your current kubeconfig is backed up
* Switching is fast, even with many clusters

---

## Common Issues

### No clusters shown

* Make sure YAML files exist in `YAML/`
* Press `r` to refresh

### Cluster not reachable
* VPN may be required
* k9s will still open

### Reset everything
rm -rf ~/.kube/rancher_prod
./k9s_cluster_manager.sh






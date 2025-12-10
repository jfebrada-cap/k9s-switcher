```markdown
# K9s Cluster Switcher

A fast, simple tool to manage Kubernetes clusters and launch k9s with one click.

---

## 📋 Prerequisites

Before you begin, install these required tools:

### For macOS
```bash
# 1. Install Homebrew (package manager)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. Install required tools
brew install kubectl      # Kubernetes command-line tool
brew install k9s          # Kubernetes terminal dashboard
brew install python       # For processing cluster configurations
```

### For Linux (Ubuntu/Debian)
```bash
# Install required tools
sudo apt-get update
sudo apt-get install -y kubectl python3 python3-pip
curl -sS https://webinstall.dev/k9s | bash
```

---

## 🚀 Quick Start

### Step 1: Download the Tool
```bash
git clone https://github.com/jfebrada-cap/k9s-switcher.git
cd k9s-switcher
```

### Step 2: Make it Executable
```bash
chmod +x k9s_cluster_manager.sh
```

### Step 3: Run It!
```bash
./k9s_cluster_manager.sh
```

---

## 🔄 Updating from Previous Version

Already using an older version? Update in one command:

```bash
cd /path/to/your/k9s-switcher
git pull origin main
./k9s_cluster_manager.sh
```

---

## ✨ What's New in This Version

| Feature | Description | How to Use |
|---------|-------------|------------|
| 🔍 **Fast Search** | Find any cluster instantly | Press `f` then type part of the name |
| 🏷️ **Smart Grouping** | Clusters sorted by environment type | Automatically applied |
| 🎨 **Color Coding** | Quick visual identification | PRD=🔴, SIT=🟢, UAT=🟣, TEST=🟡 |
| 📁 **Better Organization** | Handles complex configurations | Works automatically |

**Everything you already love still works:**
- One-click cluster switching
- Automatic k9s launching
- Certificate cleanup (no more validation errors)
- Clean two-column display

---

## 🎮 How to Use

### Navigation Guide
| Key | Action | Example |
|-----|--------|---------|
| **Numbers** | Select cluster | Type `3` then Enter |
| **r** | Refresh the list | Type `r` then Enter |
| **f** | Search for cluster | Type `f` then Enter |
| **q** | Exit the tool | Type `q` then Enter |

### Using the Search Feature
1. Press `f` from the main menu
2. Type any part of a cluster name:
   ```
   Enter cluster name (partial allowed): cards
   ```
3. View results and select a cluster or press `b` to search again, `m` for main menu

### Switching Clusters
1. Type the number of the cluster you want
2. The script will:
   - Switch your kubectl context
   - Test the connection
   - Launch k9s automatically
3. In k9s, press `0` (zero) to return to the menu

---

## 📁 File Structure

```
k9s-switcher/
├── k9s_cluster_manager.sh      # Main script - run this!
└── YAML/                        # Your cluster configuration files
    ├── prd/                     # Production clusters go here
    └── nprd/                    # Non-production clusters go here
```

**How it works:**
- Your original `.yaml` files stay in `YAML/` (never modified)
- Processed versions go to `~/.kube/rancher_prod/`
- The script cleans up certificates automatically

---

## 🔧 Troubleshooting

### Common Issues & Solutions

| Issue | Solution |
|-------|----------|
| **"Command not found" errors** | Run the prerequisites installation steps above |
| **"No clusters found"** | Make sure `.yaml` files are in the `YAML/` folder |
| **Search not finding clusters** | Check spelling, try partial names (case doesn't matter) |
| **Python errors** | Run: `pip3 install pyyaml` |
| **Certificate errors** | The script automatically removes problem certificates |

### Quick Fixes
```bash
# Force refresh all clusters
rm ~/.kube/rancher_prod_setup_complete
./k9s_cluster_switcher.sh

# Check if tools are installed
which kubectl     # Should show a path
which k9s         # Should show a path
python3 --version # Should show Python 3.x
```


**Quick Access**: Add an alias to your shell:
   ```bash
   echo "alias k9s-switch='cd ~/k9s-switcher && ./k9s_cluster_switcher.sh'" >> ~/.zshrc
   source ~/.zshrc
   # Now just type: k9s-switch
   ```

**Fast Navigation**: Use `f` + partial name instead of scrolling through 50+ clusters


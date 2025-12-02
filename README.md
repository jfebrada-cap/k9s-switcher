# K9S Cluster Switcher

## Directory Structure

```
k9s-switcher/
├── README.md                    # This documentation
├── YAML/                        # Source Kubernetes config files (untouched)
│   ├── account-management-v5-production.yaml
│   ├── acquiring-v5-30-production.yaml
│   ├── b2b-v5-29-production.yaml
│   └── ... (50+ cluster configs)
└── k9s_cluster_switcher.sh      # Main switcher script
```

### 1. First-Time Setup
```bash
# Make the script executable
chmod +x k9s_cluster_switcher.sh

# Run the switcher
./k9s_cluster_switcher.sh
```

**What happens on first run:**
-  Checks if k9s is installed (installs via Homebrew if not)
-  Creates `~/.kube/rancher_prod/` directory
-  Processes all YAML files from `./YAML/` directory
-  Removes `certificate-authority-data` from configs
-  Saves cleaned configs to `~/.kube/rancher_prod/`
-  Loads the cluster switcher interface

### 2. Subsequent Runs
After the first setup, simply run:
```bash
./k9s_cluster_switcher.sh
```

The script will automatically load your 53+ clusters and display them in a clean two-column interface.

## 🎮 How to Use

### Main Interface
When you run the script, you'll see:
```
K9S CLUSTER MANAGER
Current: [current-context-name]

Available Clusters:

1) [PROD] Account Management V5 Production    28) [PROD] Kong Centralized V5 Production
2) [PROD] Acquiring V5 30 Production          29) [PROD] Kong Egress ESB V5 Production
3) [PROD] B2B V5 29 Production                30) [PROD] Kong Ingress ESB V5 Production
... (all clusters in two columns)
```

### Navigation Options
- **Numbers 1-53** - Select cluster and launch k9s
- **r** - Refresh cluster list
- **s** - Run setup again (re-process YAML files)
- **k** - Install/check k9s
- **q** - Quit

### Cluster Selection Example
```
Select (1-53/r/s/k/q): 3
────────────────────────────────────────────
Switching to: B2B V5 29 Production
────────────────────────────────────────────
Testing connection...
Connected
Context: b2b-v5-29-production
────────────────────────────────────────────
Launching k9s...
────────────────────────────────────────────
```

## ⚙️ How It Works

### 1. Certificate Cleanup
The script automatically removes `certificate-authority-data` from all Kubernetes config files. This solves common certificate validation issues when switching between clusters.

**Source:** `./YAML/*.yaml` (untouched originals)  
**Destination:** `~/.kube/rancher_prod/*.yaml` (cleaned versions)

### 2. Smart Processing
- **First-run setup:** Processes all YAML files once, creates flag file
- **Subsequent runs:** Uses already processed files for speed
- **Auto-detection:** Checks if setup is needed

### 3. Two-Column Display
- Automatically calculates optimal column widths
- Color-codes clusters by environment (PROD=red, DEV=blue, etc.)
- Shows environment tags: [PROD], [DEV], [STAGE], etc.
- Displays current Kubernetes context

### 4. k9s Integration
- Automatically installs k9s via Homebrew if not present
- Launches k9s with selected cluster context
- Press '0' in k9s to return to the menu

## 🔄 Adding New Clusters

### Method 1: Automatic Setup
1. Add new YAML files to `./YAML/` directory
2. Run the script and press **'s'** to re-process
3. All files will be cleaned and added to the menu

### Method 2: Direct Run
1. Add new YAML files to `./YAML/` directory
2. Delete the setup flag: `rm ~/.kube/rancher_prod_setup_complete`
3. Run the script: it will detect and process new files automatically

## 📊 Features

### Automatic Features
-  Auto k9s installation via Homebrew
-  Auto certificate cleanup
-  Auto cluster detection
-  Auto terminal width adjustment

### Display Features
-  Two-column layout for 50+ clusters
-  Environment color coding
-  Current context display
-  Connection testing
-  Backup system for configs

### Management Features
-  One-time setup
-  Quick refresh
-  Easy cluster switching
-  Clean exit handling

## 🛠️ Technical Details

### Prerequisites
- macOS/Linux with bash
- Homebrew (for k9s installation)
- Kubernetes config files in YAML format

### File Processing
```bash
# Certificate removal process:
awk '
/certificate-authority-data:/ { skip = 1; next }
skip && /^[[:space:]]/ { next }
skip && /^[^[:space:]]/ { skip = 0 }
{ print }
' source.yaml > cleaned.yaml
```

### Directory Structure
- `./YAML/` - Your original kubeconfig files (never modified)
- `~/.kube/rancher_prod/` - Processed configs (certificates removed)
- `~/.kube/backups/` - Automatic backups of your main kubeconfig
- `~/.kube/rancher_prod_setup_complete` - Setup completion flag

## ❓ Troubleshooting

### Common Issues

**1. "k9s not found"**
- The script will automatically install via Homebrew
- If Homebrew isn't installed, install it first: https://brew.sh

**2. "No YAML files found"**
- Ensure your config files are in `./YAML/` directory
- Files should have `.yaml` or `.yml` extension

**3. Connection issues**
- Some clusters may require VPN
- Script tests connections with 3-second timeout

**4. Certificate errors**
- Script removes certificate-authority-data automatically
- Re-run setup with 's' option if issues persist

### Manual Overrides
```bash
# Force re-setup
rm ~/.kube/rancher_prod_setup_complete
./k9s_cluster_switcher.sh

# Check processed files
ls -la ~/.kube/rancher_prod/

# View backups
ls -la ~/.kube/backups/
```
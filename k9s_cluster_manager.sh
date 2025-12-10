#!/bin/bash

# ============================================
# K9S CLUSTER MANAGER (macOS only) - OPTIMIZED
# ============================================

# Check if running on macOS
if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: This script is designed to run only on macOS."
    exit 1
fi

# Configuration
RANCHER_DIR="${HOME}/.kube/rancher_prod"
MAIN_CONFIG="${HOME}/.kube/config"
BACKUP_DIR="${HOME}/.kube/backups"
SOURCE_YAML_DIR="./YAML"
SETUP_FLAG_FILE="${HOME}/.kube/rancher_prod_setup_complete"

# Performance cache files
CLUSTER_CACHE_FILE="${HOME}/.kube/cluster_cache.json"
CLUSTER_CACHE_TIMESTAMP="${HOME}/.kube/cluster_cache.timestamp"
YAML_PROCESS_TIMESTAMP="${HOME}/.kube/yaml_process.timestamp"

# Colors (only for headers and status messages)
BLUE='\033[38;5;39m'
GREEN='\033[38;5;46m'
YELLOW='\033[38;5;226m'
RED='\033[38;5;196m'
GRAY='\033[38;5;245m'
WHITE='\033[38;5;255m'
ORANGE='\033[38;5;214m'
NC='\033[0m'

# Environment colors for display (simpler)
PRD_COLOR='\033[38;5;196m'     # Red
SIT_COLOR='\033[38;5;46m'      # Green
UAT_COLOR='\033[38;5;129m'     # Purple
TEST_COLOR='\033[38;5;226m'    # Yellow
OTHER_COLOR='\033[38;5;214m'   # Orange

# Performance tracking
LAST_REFRESH=0
REFRESH_COOLDOWN=1  # Minimum seconds between refreshes

# Ensure directories exist
mkdir -p "$BACKUP_DIR"

# ============================================
# DEPENDENCY INSTALLATION FUNCTION 
# ============================================

install_dependencies() {
    echo -e "${BLUE}Checking and installing required dependencies for macOS...${NC}"
    
    # Check if running on Apple Silicon (M1/M2/M3) or Intel
    local arch_type
    if [[ "$(uname -m)" == "arm64" ]]; then
        arch_type="Apple Silicon"
        HOMEBREW_PREFIX="/opt/homebrew"
    else
        arch_type="Intel"
        HOMEBREW_PREFIX="/usr/local"
    fi
    echo -e "${GRAY}Detected: ${arch_type}${NC}"
    
    # Check for Homebrew (Package Manager)
    if ! command -v brew &> /dev/null; then
        echo -e "${YELLOW}Homebrew not found. Installing Homebrew...${NC}"
        echo -e "${GRAY}This may take a few minutes. Please follow the prompts if any.${NC}"
        
        # Install Homebrew with official script
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        
        # Configure Homebrew for the current shell session
        if [[ "$(uname -m)" == "arm64" ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        else
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        
        # Update Homebrew
        brew update
        echo -e "${GREEN}✓ Homebrew installed successfully${NC}"
    else
        echo -e "${GREEN}✓ Homebrew is already installed${NC}"
        
        # Update Homebrew to ensure we have latest packages
        echo -e "${GRAY}Updating Homebrew...${NC}"
        brew update
    fi
    
    # Install Python3 if not present
    if ! command -v python3 &> /dev/null; then
        echo -e "${YELLOW}Python3 not found. Installing via Homebrew...${NC}"
        brew install python@3.11
        echo -e "${GREEN}✓ Python3 installed${NC}"
    else
        echo -e "${GREEN}✓ Python3 is already installed${NC}"
    fi
    
    # Check for PyYAML
    if ! python3 -c "import yaml" &> /dev/null; then
        echo -e "${YELLOW}PyYAML not found. Installing...${NC}"
        pip3 install pyyaml
        echo -e "${GREEN}✓ PyYAML installed${NC}"
    else
        echo -e "${GREEN}✓ PyYAML is already installed${NC}"
    fi
    
    # Check for kubectl
    if ! command -v kubectl &> /dev/null; then
        echo -e "${YELLOW}kubectl not found. Installing...${NC}"
        brew install kubectl
        echo -e "${GREEN}✓ kubectl installed${NC}"
    else
        echo -e "${GREEN}✓ kubectl is already installed${NC}"
    fi
    
    # Check for k9s
    if ! command -v k9s &> /dev/null; then
        echo -e "${YELLOW}k9s not found. Installing...${NC}"
        brew install k9s
        echo -e "${GREEN}✓ k9s installed${NC}"
    else
        echo -e "${GREEN}✓ k9s is already installed${NC}"
    fi
    
    # Additional useful tools
    echo -e "${BLUE}Checking for additional useful tools...${NC}"
    
    # Check for watch command (useful for monitoring)
    if ! command -v watch &> /dev/null; then
        echo -e "${YELLOW}watch command not found. Installing...${NC}"
        brew install watch
        echo -e "${GREEN}✓ watch installed${NC}"
    fi
    
    # Check for jq (JSON processor) - important for performance
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}jq not found. Installing...${NC}"
        brew install jq
        echo -e "${GREEN}✓ jq installed${NC}"
    fi
    
    # Check for yq (YAML processor)
    if ! command -v yq &> /dev/null; then
        echo -e "${YELLOW}yq not found. Installing...${NC}"
        brew install yq
        echo -e "${GREEN}✓ yq installed${NC}"
    fi
    
    echo -e "${GREEN}✓ All dependencies installed/verified!${NC}"
    echo ""
}

# ============================================
# SIMPLE CERTIFICATE CLEANUP FUNCTION
# ============================================

clean_certificate_data() {
    local input_file="$1"
    local output_file="$2"
    
    # Use Python for reliable YAML processing
    python3 -c "
import yaml
import sys

input_file = '$input_file'
output_file = '$output_file'

try:
    with open(input_file, 'r') as f:
        config = yaml.safe_load(f)
    
    # Remove certificate-authority-data from all clusters
    if 'clusters' in config:
        for cluster in config['clusters']:
            if 'cluster' in cluster and 'certificate-authority-data' in cluster['cluster']:
                del cluster['cluster']['certificate-authority-data']
    
    # Write cleaned config
    with open(output_file, 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False)
    
    print('SUCCESS')
    
except Exception as e:
    print(f'ERROR: {e}')
    sys.exit(1)
"
}

# ============================================
# PERFORMANCE OPTIMIZED FUNCTIONS WITH PRD/NPRD SEPARATION
# ============================================

# Single Python script to process all YAML files at once
create_yaml_processor() {
    cat > /tmp/yaml_processor.py << 'PYTHON_EOF'
#!/usr/bin/env python3
import yaml
import os
import sys
import json
import glob
from datetime import datetime

def clean_certificate_data(config):
    """Remove certificate-authority-data from config"""
    if 'clusters' in config:
        for cluster in config['clusters']:
            if 'cluster' in cluster and 'certificate-authority-data' in cluster['cluster']:
                del cluster['cluster']['certificate-authority-data']
    return config

def determine_environment_type(filepath, cluster_name):
    """Determine if PRD or NPRD based on filepath and cluster name"""
    filepath_lower = filepath.lower()
    cluster_lower = cluster_name.lower() if cluster_name else ""
    
    # Check directory structure first
    if '/prd/' in filepath_lower or filepath_lower.endswith('/prd'):
        return 'prd'
    elif '/nprd/' in filepath_lower or filepath_lower.endswith('/nprd'):
        return 'nprd'
    
    # Check filename patterns
    filename = os.path.basename(filepath).lower()
    if filename.startswith('prd-') or filename.startswith('prd_'):
        return 'prd'
    elif filename.startswith('nprd-') or filename.startswith('nprd_'):
        return 'nprd'
    
    # Check cluster name patterns
    if cluster_lower:
        if ('production' in cluster_lower or 'prod' in cluster_lower) and \
           'nonprod' not in cluster_lower and 'non-prod' not in cluster_lower and \
           'staging' not in cluster_lower and 'stage' not in cluster_lower and \
           'uat' not in cluster_lower and 'sit' not in cluster_lower and 'test' not in cluster_lower:
            return 'prd'
        elif 'sit' in cluster_lower or 'systemintegration' in cluster_lower:
            return 'nprd'
        elif 'uat' in cluster_lower or 'useracceptance' in cluster_lower:
            return 'nprd'
        elif 'test' in cluster_lower or 'testing' in cluster_lower:
            return 'nprd'
        elif 'dev' in cluster_lower or 'development' in cluster_lower:
            return 'nprd'
        elif 'stage' in cluster_lower or 'staging' in cluster_lower:
            return 'nprd'
    
    # Default to nprd for safety
    return 'nprd'

def extract_single_cluster_config(full_config, cluster_name, env_type):
    """Extract single cluster from multi-cluster config"""
    # Find the specific cluster
    target_cluster = None
    target_context = None
    target_user = None
    
    for cluster in full_config.get('clusters', []):
        if cluster.get('name') == cluster_name:
            target_cluster = cluster
            break
    
    if not target_cluster:
        return None
    
    # Find context by name (same as cluster name)
    for context in full_config.get('contexts', []):
        if context.get('name') == cluster_name:
            target_context = context
            break
    
    if not target_context:
        # Create a context
        target_context = {
            'name': cluster_name,
            'context': {
                'cluster': cluster_name,
                'user': cluster_name
            }
        }
    
    # Find user by name (same as cluster name)
    for user in full_config.get('users', []):
        if user.get('name') == cluster_name:
            target_user = user
            break
    
    # Build new config
    new_config = {
        'apiVersion': 'v1',
        'kind': 'Config',
        'clusters': [target_cluster],
        'users': [target_user] if target_user else [{'name': cluster_name, 'user': {'token': ''}}],
        'contexts': [target_context],
        'current-context': cluster_name
    }
    
    # Clean certificate data
    new_config = clean_certificate_data(new_config)
    
    return new_config

def process_yaml_batch(source_dir, target_dir):
    """Process all YAML files in a single batch with PRD/NPRD separation"""
    results = {
        'processed': 0,
        'new': 0,
        'updated': 0,
        'clusters': []
    }
    
    # Process directory structure: prd/ and nprd/ subdirectories
    for env_dir_name in ['prd', 'nprd']:
        env_dir = os.path.join(source_dir, env_dir_name)
        if os.path.exists(env_dir):
            for yaml_file in glob.glob(os.path.join(env_dir, "*.yaml")) + \
                            glob.glob(os.path.join(env_dir, "*.yml")):
                try:
                    with open(yaml_file, 'r') as f:
                        config = yaml.safe_load(f)
                    
                    env_type = env_dir_name  # prd or nprd from directory
                    
                    # Check if multi-cluster
                    clusters = config.get('clusters', [])
                    
                    if len(clusters) > 1:
                        # Multi-cluster config
                        for cluster in clusters:
                            cluster_name = cluster.get('name')
                            if cluster_name:
                                # Create single cluster config
                                single_config = extract_single_cluster_config(config, cluster_name, env_type)
                                if single_config:
                                    output_file = os.path.join(target_dir, f"{env_type}_{cluster_name}.yaml")
                                    needs_update = not os.path.exists(output_file) or os.path.getmtime(yaml_file) > os.path.getmtime(output_file)
                                    
                                    if needs_update:
                                        with open(output_file, 'w') as f:
                                            yaml.dump(single_config, f, default_flow_style=False, sort_keys=False)
                                        results['updated'] += 1
                                    
                                    results['clusters'].append({
                                        'source': yaml_file,
                                        'name': cluster_name,
                                        'env_type': env_type.upper(),
                                        'output_file': output_file,
                                        'needs_update': needs_update
                                    })
                    else:
                        # Single cluster config
                        cluster_name = None
                        if clusters:
                            cluster_name = clusters[0].get('name')
                        if not cluster_name and 'current-context' in config:
                            cluster_name = config['current-context']
                        if not cluster_name:
                            cluster_name = os.path.splitext(os.path.basename(yaml_file))[0]
                            # Remove prd- or nprd- prefix if present
                            if cluster_name.startswith('prd-'):
                                cluster_name = cluster_name[4:]
                            elif cluster_name.startswith('nprd-'):
                                cluster_name = cluster_name[5:]
                        
                        output_file = os.path.join(target_dir, f"{env_type}_{cluster_name}.yaml")
                        needs_update = not os.path.exists(output_file) or os.path.getmtime(yaml_file) > os.path.getmtime(output_file)
                        
                        if needs_update:
                            # Clean certificate data
                            config = clean_certificate_data(config)
                            with open(output_file, 'w') as f:
                                yaml.dump(config, f, default_flow_style=False, sort_keys=False)
                            results['updated'] += 1
                        
                        results['clusters'].append({
                            'source': yaml_file,
                            'name': cluster_name,
                            'env_type': env_type.upper(),
                            'output_file': output_file,
                            'needs_update': needs_update
                        })
                    
                    results['processed'] += 1
                    
                except Exception as e:
                    print(f"Error processing {yaml_file}: {e}", file=sys.stderr)
                    continue
    
    # Process root directory files (backward compatibility)
    for yaml_file in glob.glob(os.path.join(source_dir, "*.yaml")) + \
                     glob.glob(os.path.join(source_dir, "*.yml")):
        # Skip files already processed from subdirectories
        if not any(env in yaml_file for env in ['/prd/', '/nprd/']):
            try:
                with open(yaml_file, 'r') as f:
                    config = yaml.safe_load(f)
                
                # Extract cluster name first
                cluster_name = None
                clusters = config.get('clusters', [])
                if clusters:
                    cluster_name = clusters[0].get('name')
                if not cluster_name and 'current-context' in config:
                    cluster_name = config['current-context']
                if not cluster_name:
                    cluster_name = os.path.splitext(os.path.basename(yaml_file))[0]
                
                # Determine environment type
                env_type = determine_environment_type(yaml_file, cluster_name)
                
                # Check if multi-cluster
                if len(clusters) > 1:
                    # Multi-cluster config
                    for cluster in clusters:
                        cluster_name = cluster.get('name')
                        if cluster_name:
                            # Re-determine env type for each cluster
                            cluster_env_type = determine_environment_type(yaml_file, cluster_name)
                            single_config = extract_single_cluster_config(config, cluster_name, cluster_env_type)
                            if single_config:
                                output_file = os.path.join(target_dir, f"{cluster_env_type}_{cluster_name}.yaml")
                                needs_update = not os.path.exists(output_file) or os.path.getmtime(yaml_file) > os.path.getmtime(output_file)
                                
                                if needs_update:
                                    with open(output_file, 'w') as f:
                                        yaml.dump(single_config, f, default_flow_style=False, sort_keys=False)
                                    results['updated'] += 1
                                
                                results['clusters'].append({
                                    'source': yaml_file,
                                    'name': cluster_name,
                                    'env_type': cluster_env_type.upper(),
                                    'output_file': output_file,
                                    'needs_update': needs_update
                                })
                else:
                    # Single cluster config
                    output_file = os.path.join(target_dir, f"{env_type}_{cluster_name}.yaml")
                    needs_update = not os.path.exists(output_file) or os.path.getmtime(yaml_file) > os.path.getmtime(output_file)
                    
                    if needs_update:
                        # Clean certificate data
                        config = clean_certificate_data(config)
                        with open(output_file, 'w') as f:
                            yaml.dump(config, f, default_flow_style=False, sort_keys=False)
                        results['updated'] += 1
                    
                    results['clusters'].append({
                        'source': yaml_file,
                        'name': cluster_name,
                        'env_type': env_type.upper(),
                        'output_file': output_file,
                        'needs_update': needs_update
                    })
                
                results['processed'] += 1
                
            except Exception as e:
                print(f"Error processing {yaml_file}: {e}", file=sys.stderr)
                continue
    
    return results

def build_cluster_cache(target_dir):
    """Build cache of all cluster files"""
    cache = {}
    
    for cluster_file in glob.glob(os.path.join(target_dir, "*.yaml")) + glob.glob(os.path.join(target_dir, "*.yml")):
        if os.path.isfile(cluster_file):
            try:
                with open(cluster_file, 'r') as f:
                    config = yaml.safe_load(f)
                
                filename = os.path.basename(cluster_file)
                filename_no_ext = os.path.splitext(filename)[0]
                
                # Extract cluster name
                cluster_name = None
                if 'contexts' in config and len(config['contexts']) > 0:
                    cluster_name = config['contexts'][0].get('name')
                if not cluster_name and 'clusters' in config and len(config['clusters']) > 0:
                    cluster_name = config['clusters'][0].get('name')
                if not cluster_name:
                    cluster_name = config.get('current-context', filename_no_ext)
                
                # Remove prd_ or nprd_ prefix from cluster name for display
                display_name = cluster_name
                if display_name and display_name.startswith('prd_'):
                    display_name = display_name[4:]
                elif display_name and display_name.startswith('nprd_'):
                    display_name = display_name[5:]
                
                # Check if certificate is cleaned
                certificate_cleaned = True
                for cluster in config.get('clusters', []):
                    if 'cluster' in cluster:
                        if 'certificate-authority-data' in cluster['cluster']:
                            certificate_cleaned = False
                            break
                
                # Determine environment type from filename
                env_type = "OTHER"
                if filename.startswith('prd_'):
                    env_type = "PRD"
                elif filename.startswith('nprd_'):
                    # Determine specific non-prod environment
                    name_lower = (display_name or '').lower()
                    if 'sit' in name_lower or 'systemintegration' in name_lower:
                        env_type = "SIT"
                    elif 'uat' in name_lower or 'useracceptance' in name_lower:
                        env_type = "UAT"
                    elif 'test' in name_lower or 'testing' in name_lower:
                        env_type = "TEST"
                    elif 'dev' in name_lower or 'development' in name_lower:
                        env_type = "DEV"
                    elif 'stage' in name_lower or 'staging' in name_lower:
                        env_type = "STAGE"
                    elif 'perf' in name_lower or 'performance' in name_lower:
                        env_type = "PERF"
                    else:
                        env_type = "OTHER"
                
                cache[filename] = {
                    'path': cluster_file,
                    'cluster_name': cluster_name,
                    'display_name': display_name or filename_no_ext,
                    'env_type': env_type,
                    'certificate_cleaned': certificate_cleaned,
                    'mod_time': os.path.getmtime(cluster_file)
                }
                
            except Exception as e:
                print(f"Error caching {cluster_file}: {e}", file=sys.stderr)
                continue
    
    return cache

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: yaml_processor.py <source_dir> <target_dir> <command>")
        print("Commands: process, cache")
        sys.exit(1)
    
    source_dir = sys.argv[1]
    target_dir = sys.argv[2]
    command = sys.argv[3] if len(sys.argv) > 3 else "process"
    
    os.makedirs(target_dir, exist_ok=True)
    
    if command == "process":
        results = process_yaml_batch(source_dir, target_dir)
        print(json.dumps(results))
    elif command == "cache":
        cache = build_cluster_cache(target_dir)
        print(json.dumps(cache))
PYTHON_EOF
}

# ============================================
# SIMPLE YAML PROCESSING FUNCTION
# ============================================

process_yaml_files() {
    echo -e "${BLUE}Processing YAML files...${NC}"
    
    # Check if source directory exists
    if [ ! -d "$SOURCE_YAML_DIR" ]; then
        echo -e "${RED}Error: Source YAML directory not found${NC}"
        return 1
    fi
    
    # Create rancher_prod directory
    mkdir -p "$RANCHER_DIR"
    
    # Create YAML processor
    create_yaml_processor
    
    # Process all YAML files
    local results
    results=$(python3 /tmp/yaml_processor.py "$SOURCE_YAML_DIR" "$RANCHER_DIR" "process" 2>/dev/null)
    
    if [ -n "$results" ]; then
        local processed=$(echo "$results" | python3 -c "import json, sys; data=json.load(sys.stdin); print(data.get('processed', 0))")
        local updated=$(echo "$results" | python3 -c "import json, sys; data=json.load(sys.stdin); print(data.get('updated', 0))")
        
        # Count PRD vs NPRD
        local prd_count=$(echo "$results" | python3 -c "
import json, sys
data = json.load(sys.stdin)
prd = 0
for cluster in data.get('clusters', []):
    if cluster.get('env_type') == 'PRD':
        prd += 1
print(prd)
" 2>/dev/null || echo "0")
        
        local nprd_count=$(echo "$results" | python3 -c "
import json, sys
data = json.load(sys.stdin)
nprd = 0
for cluster in data.get('clusters', []):
    if cluster.get('env_type') != 'PRD':
        nprd += 1
print(nprd)
" 2>/dev/null || echo "0")
        
        echo -e "${GREEN}✓ Processed $processed files, updated $updated clusters${NC}"
        echo -e "${GRAY}  PRD: $prd_count, Non-PRD: $nprd_count${NC}"
        
        # Verify certificate cleanup
        echo -e "${GRAY}Verifying certificate cleanup...${NC}"
        local unclean_count=0
        for file in "$RANCHER_DIR"/*.yaml "$RANCHER_DIR"/*.yml; do
            [ -f "$file" ] || continue
            if grep -q "certificate-authority-data:" "$file"; then
                echo -e "${YELLOW}  Warning: $file still contains certificate data${NC}"
                unclean_count=$((unclean_count + 1))
            fi
        done
        
        if [ $unclean_count -eq 0 ]; then
            echo -e "${GREEN}✓ All certificates cleaned successfully${NC}"
        else
            echo -e "${YELLOW}  Found $unclean_count files with certificate data${NC}"
        fi
        
        # Update cache
        update_cluster_cache
    else
        echo -e "${YELLOW}No YAML files found to process${NC}"
    fi
    
    # Update timestamp
    date +%s > "$YAML_PROCESS_TIMESTAMP"
    
    return 0
}

# ============================================
# CLUSTER CACHE MANAGEMENT
# ============================================

update_cluster_cache() {
    # Create YAML processor if needed
    if [ ! -f "/tmp/yaml_processor.py" ]; then
        create_yaml_processor
    fi
    
    # Build cache using Python
    python3 /tmp/yaml_processor.py "$SOURCE_YAML_DIR" "$RANCHER_DIR" "cache" > "$CLUSTER_CACHE_FILE" 2>/dev/null
    
    if [ $? -eq 0 ] && [ -s "$CLUSTER_CACHE_FILE" ]; then
        echo -e "${GRAY}✓ Cluster cache updated${NC}"
        date +%s > "$CLUSTER_CACHE_TIMESTAMP"
    fi
    
    # Clear arrays to force reload
    unset PRD_CLUSTERS SIT_CLUSTERS UAT_CLUSTERS TEST_CLUSTERS OTHER_CLUSTERS
    unset CLUSTER_CACHE_DATA
}

load_cluster_cache() {
    # Check if cache needs update
    local cache_age=0
    if [ -f "$CLUSTER_CACHE_TIMESTAMP" ]; then
        local cache_time=$(cat "$CLUSTER_CACHE_TIMESTAMP")
        local current_time=$(date +%s)
        cache_age=$((current_time - cache_time))
    fi
    
    if [ ! -f "$CLUSTER_CACHE_FILE" ] || [ $cache_age -gt 300 ] || [ ! -s "$CLUSTER_CACHE_FILE" ]; then
        update_cluster_cache
    fi
    
    # Load cache if not already loaded
    if [ -z "${CLUSTER_CACHE_DATA+x}" ] || [ ! -f "$CLUSTER_CACHE_FILE" ]; then
        if [ -f "$CLUSTER_CACHE_FILE" ]; then
            CLUSTER_CACHE_DATA=$(cat "$CLUSTER_CACHE_FILE")
        else
            CLUSTER_CACHE_DATA="{}"
        fi
    fi
}

# ============================================
# HELPER FUNCTIONS
# ============================================

get_actual_cluster_name() {
    local file="$1"
    local filename=$(basename "$file")
    
    # Try to get from cache first
    if [ -n "$CLUSTER_CACHE_DATA" ] && [ "$CLUSTER_CACHE_DATA" != "{}" ]; then
        local cached_name=$(echo "$CLUSTER_CACHE_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    filename = '$filename'
    if filename in data:
        print(data[filename].get('display_name', ''))
    else:
        print('')
except:
    print('')
" 2>/dev/null)
        
        if [ -n "$cached_name" ]; then
            echo "$cached_name"
            return
        fi
    fi
    
    # Fallback: extract from file
    local name=$(awk '
        /^\s*current-context:\s*/ {
            gsub(/^[ \t]*current-context:[ \t]*/, "");
            gsub(/["'\'']/, "");
            print;
            exit
        }
    ' "$file" 2>/dev/null)
    
    if [ -z "$name" ]; then
        name=$(basename "$file")
        name="${name%.*}"
        name="${name#prd_}"
        name="${name#nprd_}"
    fi
    
    echo "$name"
}

get_environment_type() {
    local name="$1"
    local lower_name=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$name" == prd_* ]] || [[ $lower_name =~ production|prod ]] && [[ ! $lower_name =~ non-prod|nonprod ]]; then
        echo "PRD"
    elif [[ $lower_name =~ sit|systemintegration ]]; then
        echo "SIT"
    elif [[ $lower_name =~ uat|useracceptance ]]; then
        echo "UAT"
    elif [[ $lower_name =~ test|testing ]]; then
        echo "TEST"
    elif [[ $lower_name =~ dev|development ]]; then
        echo "DEV"
    elif [[ $lower_name =~ perf|performance|load ]]; then
        echo "PERF"
    elif [[ $lower_name =~ stage|staging ]]; then
        echo "STAGE"
    else
        echo "OTHER"
    fi
}

get_environment_color() {
    local env_type="$1"
    case $env_type in
        "PRD") echo "$PRD_COLOR" ;;
        "SIT") echo "$SIT_COLOR" ;;
        "UAT") echo "$UAT_COLOR" ;;
        "TEST") echo "$TEST_COLOR" ;;
        "DEV") echo "$TEST_COLOR" ;;
        "PERF") echo "$UAT_COLOR" ;;
        "STAGE") echo "$OTHER_COLOR" ;;
        *) echo "$OTHER_COLOR" ;;
    esac
}

format_cluster_name() {
    local name="$1"
    # Remove prd_ or nprd_ prefix for display
    name="${name#prd_}"
    name="${name#nprd_}"
    # Truncate if too long
    if [ ${#name} -gt 40 ]; then
        name="${name:0:37}..."
    fi
    echo "$name"
}

# ============================================
# OPTIMIZED CLUSTER LOADING
# ============================================

get_all_clusters() {
    # Use cached data for faster loading
    load_cluster_cache
    
    # Initialize arrays
    PRD_CLUSTERS=()
    SIT_CLUSTERS=()
    UAT_CLUSTERS=()
    TEST_CLUSTERS=()
    OTHER_CLUSTERS=()
    
    # Parse cache data efficiently
    if command -v jq &> /dev/null && [ -n "$CLUSTER_CACHE_DATA" ] && [ "$CLUSTER_CACHE_DATA" != "{}" ]; then
        # Use jq for fast JSON parsing
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                local filepath=$(echo "$line" | cut -d'|' -f1)
                local env_type=$(echo "$line" | cut -d'|' -f2)
                
                case $env_type in
                    "PRD") PRD_CLUSTERS+=("$filepath") ;;
                    "SIT") SIT_CLUSTERS+=("$filepath") ;;
                    "UAT") UAT_CLUSTERS+=("$filepath") ;;
                    "TEST") TEST_CLUSTERS+=("$filepath") ;;
                    *) OTHER_CLUSTERS+=("$filepath") ;;
                esac
            fi
        done < <(echo "$CLUSTER_CACHE_DATA" | jq -r 'to_entries[] | "\(.value.path)|\(.value.env_type)"' 2>/dev/null)
    else
        # Fallback: read files directly
        while IFS= read -r file; do
            if [ -f "$file" ]; then
                filename=$(basename "$file")
                
                # Try to get env type from cache
                local env_type="OTHER"
                if [ -n "$CLUSTER_CACHE_DATA" ] && [ "$CLUSTER_CACHE_DATA" != "{}" ]; then
                    env_type=$(echo "$CLUSTER_CACHE_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    filename = '$filename'
    if filename in data:
        print(data[filename].get('env_type', 'OTHER'))
    else:
        print('OTHER')
except:
    print('OTHER')
" 2>/dev/null)
                else
                    # Fallback to filename-based detection
                    if [[ "$filename" == prd_* ]]; then
                        env_type="PRD"
                    else
                        actual_name=$(get_actual_cluster_name "$file")
                        env_type=$(get_environment_type "${actual_name:-$filename}")
                    fi
                fi
                
                case $env_type in
                    "PRD") PRD_CLUSTERS+=("$file") ;;
                    "SIT") SIT_CLUSTERS+=("$file") ;;
                    "UAT") UAT_CLUSTERS+=("$file") ;;
                    "TEST") TEST_CLUSTERS+=("$file") ;;
                    *) OTHER_CLUSTERS+=("$file") ;;
                esac
            fi
        done < <(find "$RANCHER_DIR" -maxdepth 1 \( -name "*.yaml" -o -name "*.yml" \) -type f 2>/dev/null | sort)
    fi
}

# ============================================
# TERMINAL FUNCTIONS
# ============================================

show_current_context() {
    if [ -f "$MAIN_CONFIG" ]; then
        current_ctx=$(kubectl config current-context 2>/dev/null || echo "None")
        echo -e "${GRAY}Current: ${WHITE}$current_ctx${NC}"
    else
        echo -e "${GRAY}Current: ${RED}None${NC}"
    fi
}

# ============================================
# DISPLAY FUNCTIONS
# ============================================

display_environment_clusters() {
    local env_name="$1"
    local clusters_array_name="$2"
    local start_number="$3"
    
    eval "local clusters_array=(\"\${$clusters_array_name[@]}\")"
    local total=${#clusters_array[@]}
    
    if [ $total -eq 0 ]; then
        return
    fi
    
    local per_col=$(( (total + 1) / 2 ))
    
    for ((i=0; i<per_col; i++)); do
        # Column 1
        idx1=$i
        line1=""
        if [ $idx1 -lt $total ]; then
            cluster_path="${clusters_array[$idx1]}"
            filename=$(basename "$cluster_path")
            
            # Get display name from cache
            local display_name
            if [ -n "$CLUSTER_CACHE_DATA" ] && [ "$CLUSTER_CACHE_DATA" != "{}" ]; then
                display_name=$(echo "$CLUSTER_CACHE_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if '$filename' in data:
        print(data['$filename'].get('display_name', '$filename'))
    else:
        print('$filename')
except:
    print('$filename')
" 2>/dev/null)
            else
                display_name=$(format_cluster_name "$filename")
            fi
            
            # Truncate if too long
            if [ ${#display_name} -gt 35 ]; then
                display_name="${display_name:0:32}..."
            fi
            
            number=$((start_number + idx1))
            env_color=$(get_environment_color "$env_name")
            line1=$(printf "  ${env_color}%3d) [${env_name}] %-45s${NC}" "$number" "$display_name")
        fi
        
        # Column 2
        idx2=$((i + per_col))
        line2=""
        if [ $idx2 -lt $total ]; then
            cluster_path="${clusters_array[$idx2]}"
            filename=$(basename "$cluster_path")
            
            # Get display name from cache
            local display_name
            if [ -n "$CLUSTER_CACHE_DATA" ] && [ "$CLUSTER_CACHE_DATA" != "{}" ]; then
                display_name=$(echo "$CLUSTER_CACHE_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if '$filename' in data:
        print(data['$filename'].get('display_name', '$filename'))
    else:
        print('$filename')
except:
    print('$filename')
" 2>/dev/null)
            else
                display_name=$(format_cluster_name "$filename")
            fi
            
            # Truncate if too long
            if [ ${#display_name} -gt 35 ]; then
                display_name="${display_name:0:32}..."
            fi
            
            number=$((start_number + idx2))
            env_color=$(get_environment_color "$env_name")
            line2=$(printf "  ${env_color}%3d) [${env_name}] %s${NC}" "$number" "$display_name")
        fi
        
        echo -e "${line1}${line2}"
    done
}

show_grouped_table_menu() {
    local now=$(date +%s)
    if [ $((now - LAST_REFRESH)) -lt $REFRESH_COOLDOWN ] && [ ${#PRD_CLUSTERS[@]} -gt 0 ]; then
        # Use cached data
        :
    else
        clear
        LAST_REFRESH=$now
        
        echo -e "${BLUE}K9S CLUSTER MANAGER (macOS)${NC}"
        show_current_context
        echo ""

        get_all_clusters
    fi
    
    local total_prd=${#PRD_CLUSTERS[@]}
    local total_sit=${#SIT_CLUSTERS[@]}
    local total_uat=${#UAT_CLUSTERS[@]}
    local total_test=${#TEST_CLUSTERS[@]}
    local total_other=${#OTHER_CLUSTERS[@]}
    local total_clusters=$((total_prd + total_sit + total_uat + total_test + total_other))

    if [ $total_clusters -eq 0 ]; then
        echo -e "${YELLOW}No clusters found${NC}"
        echo ""
        echo -e "${WHITE}Navigation:${NC}"
        echo ""
        echo -e "  ${YELLOW}r${WHITE}            Refresh list"
        echo -e "  ${RED}q${WHITE}            Quit"
        return 1
    fi

    # Display PRD clusters first
    if [ $total_prd -gt 0 ]; then
        echo -e "${RED}┌────────────────────────────────────────────────────┐${NC}"
        echo -e "${RED}│               PRODUCTION CLUSTERS                  │${NC}"
        echo -e "${RED}└────────────────────────────────────────────────────┘${NC}"
        echo ""
        
        display_environment_clusters "PRD" PRD_CLUSTERS 1
        echo ""
    fi
    
    # Display non-PRD environments
    echo -e "${BLUE}┌────────────────────────────────────────────────────┐${NC}"
    echo -e "${BLUE}│           NON-PRODUCTION CLUSTERS                  │${NC}"
    echo -e "${BLUE}└────────────────────────────────────────────────────┘${NC}"
    echo ""
    
    local start_number=$((total_prd + 1))
    
    # Display SIT clusters
    if [ $total_sit -gt 0 ]; then
        echo -e "${SIT_COLOR}SIT CLUSTERS:${NC}"
        display_environment_clusters "SIT" SIT_CLUSTERS $start_number
        start_number=$((start_number + total_sit))
        echo ""
    fi
    
    # Display UAT clusters
    if [ $total_uat -gt 0 ]; then
        echo -e "${UAT_COLOR}UAT CLUSTERS:${NC}"
        display_environment_clusters "UAT" UAT_CLUSTERS $start_number
        start_number=$((start_number + total_uat))
        echo ""
    fi
    
    # Display TEST clusters
    if [ $total_test -gt 0 ]; then
        echo -e "${TEST_COLOR}TEST CLUSTERS:${NC}"
        display_environment_clusters "TEST" TEST_CLUSTERS $start_number
        start_number=$((start_number + total_test))
        echo ""
    fi
    
    # Display OTHER clusters
    if [ $total_other -gt 0 ]; then
        echo -e "${OTHER_COLOR}OTHER CLUSTERS:${NC}"
        display_environment_clusters "OTHER" OTHER_CLUSTERS $start_number
    fi
    
    echo ""
    echo -e "${BLUE}────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${GRAY}Total: ${WHITE}$total_clusters${GRAY} clusters"
    echo -e "${RED}$total_prd PRD${GRAY}, ${SIT_COLOR}$total_sit SIT${GRAY}, ${UAT_COLOR}$total_uat UAT${GRAY}, ${TEST_COLOR}$total_test TEST${GRAY}, ${OTHER_COLOR}$total_other OTHER${NC}"
    echo ""

    echo -e "${WHITE}Navigation:${NC}"
    echo ""
    echo -e "  ${GREEN}1-$total_clusters${WHITE}  Select cluster"
    echo -e "  ${YELLOW}r${WHITE}            Refresh list"
    echo -e "  ${ORANGE}f${WHITE}            Find cluster by name"
    echo -e "  ${RED}q${WHITE}            Quit"
    echo ""
}

# ============================================
# CLUSTER OPERATIONS
# ============================================

switch_to_cluster() {
    local cluster_path="$1"
    local filename=$(basename "$cluster_path")
    local actual_name=$(get_actual_cluster_name "$cluster_path")
    local display_name=$(format_cluster_name "${actual_name:-$filename}")

    echo ""
    echo -e "${BLUE}────────────────────────────────────────────${NC}"
    echo -e "${BLUE}Switching to: ${WHITE}$display_name${NC}"
    echo -e "${BLUE}────────────────────────────────────────────${NC}"

    # Backup current config
    if [ -f "$MAIN_CONFIG" ]; then
        cp "$MAIN_CONFIG" "$BACKUP_DIR/config.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    # Copy the cleaned config
    cp "$cluster_path" "$MAIN_CONFIG"
    export KUBECONFIG="$MAIN_CONFIG"
    
    # Verify certificate cleanup
    if grep -q "certificate-authority-data:" "$MAIN_CONFIG"; then
        echo -e "${YELLOW}Warning: Config contains certificate data, cleaning...${NC}"
        clean_certificate_data "$MAIN_CONFIG" "$MAIN_CONFIG.tmp" && mv "$MAIN_CONFIG.tmp" "$MAIN_CONFIG"
    fi

    echo -e "${GRAY}Testing connection...${NC}"
    kubectl cluster-info --request-timeout=3s >/dev/null 2>&1 && \
        echo -e "${GREEN}Connected${NC}" || \
        echo -e "${YELLOW}May require VPN${NC}"

    echo -e "${GRAY}Context: ${WHITE}$(kubectl config current-context 2>/dev/null || echo "unknown")${NC}"
}

launch_k9s() {
    echo ""
    echo -e "${BLUE}────────────────────────────────────────────${NC}"
    echo -e "${GREEN}Launching k9s...${NC}"
    echo -e "${GRAY}Press '0' to return to menu${NC}"
    echo -e "${BLUE}────────────────────────────────────────────${NC}"
    echo ""

    clear
    k9s

    echo ""
    echo -e "${BLUE}────────────────────────────────────────────${NC}"
    echo -e "${BLUE}Back to menu${NC}"
    echo -e "${BLUE}────────────────────────────────────────────${NC}"
    echo ""
}

# ============================================
# MANUAL SEARCH
# ============================================

manual_search_cluster() {
    while true; do
        clear
        echo -e "${BLUE}K9S CLUSTER MANAGER - SEARCH${NC}"
        show_current_context
        echo ""
        echo -e "${BLUE}Enter cluster name (partial allowed, or 'b' to go back):${NC}"
        read -r search

        if [[ "$search" == "b" || "$search" == "B" ]]; then
            return
        fi

        # Load cache for search
        load_cluster_cache
        
        # Search through cache
        local matches=()
        if [ -n "$CLUSTER_CACHE_DATA" ] && [ "$CLUSTER_CACHE_DATA" != "{}" ]; then
            # Use Python for searching
            while IFS= read -r filepath; do
                [ -n "$filepath" ] && matches+=("$filepath")
            done < <(echo "$CLUSTER_CACHE_DATA" | python3 -c "
import json, sys
search_term = '$search'.lower()
try:
    data = json.load(sys.stdin)
    for filename, info in data.items():
        display_name = info.get('display_name', '').lower()
        if search_term in display_name:
            print(info['path'])
except:
    pass
" 2>/dev/null)
        else
            # Fallback search
            get_all_clusters
            ALL_CLUSTERS_LIST=()
            for cluster in "${PRD_CLUSTERS[@]}"; do ALL_CLUSTERS_LIST+=("$cluster"); done
            for cluster in "${SIT_CLUSTERS[@]}"; do ALL_CLUSTERS_LIST+=("$cluster"); done
            for cluster in "${UAT_CLUSTERS[@]}"; do ALL_CLUSTERS_LIST+=("$cluster"); done
            for cluster in "${TEST_CLUSTERS[@]}"; do ALL_CLUSTERS_LIST+=("$cluster"); done
            for cluster in "${OTHER_CLUSTERS[@]}"; do ALL_CLUSTERS_LIST+=("$cluster"); done
            
            for cluster in "${ALL_CLUSTERS_LIST[@]}"; do
                filename=$(basename "$cluster")
                actual_name=$(get_actual_cluster_name "$cluster")
                display_name=$(format_cluster_name "${actual_name:-$filename}")
                lower_name=$(echo "$display_name" | tr '[:upper:]' '[:lower:]')
                lower_search=$(echo "$search" | tr '[:upper:]' '[:lower:]')
                
                [[ "$lower_name" == *"$lower_search"* ]] && matches+=("$cluster")
            done
        fi

        if [ ${#matches[@]} -eq 0 ]; then
            echo ""
            echo -e "${RED}No matching clusters found${NC}"
            sleep 1
            continue
        fi

        clear
        echo -e "${BLUE}K9S CLUSTER MANAGER - SEARCH RESULTS${NC}"
        show_current_context
        echo ""
        echo -e "${GREEN}Found ${#matches[@]} matching cluster(s):${NC}"
        echo ""

        for ((i=0; i<${#matches[@]}; i++)); do
            cluster_path="${matches[$i]}"
            filename=$(basename "$cluster_path")
            actual_name=$(get_actual_cluster_name "$cluster_path")
            display_name=$(format_cluster_name "${actual_name:-$filename}")
            
            # Get environment
            local env_type="OTHER"
            if [ -n "$CLUSTER_CACHE_DATA" ] && [ "$CLUSTER_CACHE_DATA" != "{}" ]; then
                env_type=$(echo "$CLUSTER_CACHE_DATA" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for fname, info in data.items():
        if info.get('path') == '$cluster_path':
            print(info.get('env_type', 'OTHER'))
            break
except:
    print('OTHER')
" 2>/dev/null || echo "OTHER")
            else
                env_type=$(get_environment_type "${actual_name:-$filename}")
            fi
            
            env_color=$(get_environment_color "$env_type")
            echo -e "  ${env_color}$((i+1))) [${env_type}] ${display_name}${NC}"
        done

        echo ""
        echo -e "${WHITE}Navigation:${NC}"
        echo ""
        echo -e "  ${GREEN}1-${#matches[@]}${WHITE}  Select cluster"
        echo -e "  ${YELLOW}b${WHITE}            Back to search"
        echo -e "  ${RED}m${WHITE}            Back to main menu"
        echo ""
        echo -n -e "${BLUE}Select (1-${#matches[@]}/b/m): ${NC}"
        read -r pick

        case $pick in
            b|B) continue ;;
            m|M) return ;;
            [1-9]|[1-9][0-9])
                local idx=$((pick-1))
                if [ $idx -lt ${#matches[@]} ]; then
                    switch_to_cluster "${matches[$idx]}"
                    launch_k9s
                    return
                else
                    echo -e "${RED}Invalid selection${NC}"
                    sleep 1
                fi
                ;;
            *)
                echo -e "${RED}Invalid choice${NC}"
                sleep 1
                ;;
        esac
    done
}

# ============================================
# MAIN LOOP
# ============================================

main_loop() {
    while true; do
        show_grouped_table_menu

        if [ $? -ne 0 ]; then
            echo -n -e "${BLUE}Select option (r/q): ${NC}"
        else
            local total_prd=${#PRD_CLUSTERS[@]}
            local total_sit=${#SIT_CLUSTERS[@]}
            local total_uat=${#UAT_CLUSTERS[@]}
            local total_test=${#TEST_CLUSTERS[@]}
            local total_other=${#OTHER_CLUSTERS[@]}
            local total_clusters=$((total_prd + total_sit + total_uat + total_test + total_other))
            echo -n -e "${BLUE}Select (1-$total_clusters/r/f/q): ${NC}"
        fi

        read -r choice

        case $choice in
            [1-9]|[1-9][0-9]|[1-9][0-9][0-9])
                local idx=$((choice-1))
                # Combine all clusters
                ALL_CLUSTERS_LIST=()
                for cluster in "${PRD_CLUSTERS[@]}"; do ALL_CLUSTERS_LIST+=("$cluster"); done
                for cluster in "${SIT_CLUSTERS[@]}"; do ALL_CLUSTERS_LIST+=("$cluster"); done
                for cluster in "${UAT_CLUSTERS[@]}"; do ALL_CLUSTERS_LIST+=("$cluster"); done
                for cluster in "${TEST_CLUSTERS[@]}"; do ALL_CLUSTERS_LIST+=("$cluster"); done
                for cluster in "${OTHER_CLUSTERS[@]}"; do ALL_CLUSTERS_LIST+=("$cluster"); done
                
                if [ -n "${ALL_CLUSTERS_LIST[$idx]}" ]; then
                    switch_to_cluster "${ALL_CLUSTERS_LIST[$idx]}"
                    launch_k9s
                else
                    echo -e "${RED}Invalid selection${NC}"
                    sleep 1
                fi
                ;;
            r|R)
                echo -e "${GRAY}Refreshing...${NC}"
                update_cluster_cache
                unset PRD_CLUSTERS SIT_CLUSTERS UAT_CLUSTERS TEST_CLUSTERS OTHER_CLUSTERS
                sleep 0.3
                ;;
            f|F)
                manual_search_cluster
                ;;
            q|Q)
                echo -e "\n${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice${NC}"
                sleep 1
                ;;
        esac
    done
}

# ============================================
# STARTUP
# ============================================

clear
echo -e "${BLUE}K9S CLUSTER MANAGER (macOS)${NC}"
echo ""

# Install dependencies on first run
if [ ! -f "$SETUP_FLAG_FILE" ]; then
    echo -e "${YELLOW}First-time setup detected. Installing dependencies...${NC}"
    install_dependencies
    touch "$SETUP_FLAG_FILE"
    echo -e "${GREEN}✓ Setup complete!${NC}"
    echo ""
    sleep 1
fi

# Check for new YAML files
echo -e "${BLUE}Checking for new or updated YAML files...${NC}"

need_processing=0
if [ ! -f "$YAML_PROCESS_TIMESTAMP" ]; then
    need_processing=1
elif [ ! -d "$RANCHER_DIR" ] || [ -z "$(ls -A "$RANCHER_DIR" 2>/dev/null)" ]; then
    need_processing=1
else
    last_processed=$(cat "$YAML_PROCESS_TIMESTAMP" 2>/dev/null || echo "0")
    source_newest=$(find "$SOURCE_YAML_DIR" -type f \( -name "*.yaml" -o -name "*.yml" \) -exec stat -f %m {} \; 2>/dev/null | sort -rn | head -1 2>/dev/null || echo "0")
    [ "$source_newest" -gt "$last_processed" ] && need_processing=1
fi

if [ $need_processing -eq 1 ]; then
    process_yaml_files
else
    echo -e "${GREEN}✓ YAML files already up to date${NC}"
    load_cluster_cache
fi

sleep 0.5
clear

main_loop
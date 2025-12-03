#!/bin/bash

# ============================================
# K9S CLUSTER SWITCHER 
# ============================================

# Configuration
RANCHER_DIR="${HOME}/.kube/rancher_prod"
MAIN_CONFIG="${HOME}/.kube/config"
BACKUP_DIR="${HOME}/.kube/backups"
SOURCE_YAML_DIR="./YAML"
SETUP_FLAG_FILE="${HOME}/.kube/rancher_prod_setup_complete"

# Colors (only for headers and status messages)
BLUE='\033[38;5;39m'
GREEN='\033[38;5;46m'
YELLOW='\033[38;5;226m'
RED='\033[38;5;196m'
GRAY='\033[38;5;245m'
WHITE='\033[38;5;255m'
NC='\033[0m'

# Environment colors for display (simpler)
PRD_COLOR='\033[38;5;196m'     # Red
SIT_COLOR='\033[38;5;46m'      # Green
UAT_COLOR='\033[38;5;129m'     # Purple
TEST_COLOR='\033[38;5;226m'    # Yellow
OTHER_COLOR='\033[38;5;214m'   # Orange

# Ensure directories exist
mkdir -p "$BACKUP_DIR"

# ============================================
# SETUP FUNCTIONS (unchanged)
# ============================================

# Function to extract single cluster from multi-cluster config
extract_single_cluster() {
    local source_file="$1"
    local cluster_name="$2"
    local output_file="$3"
    
    # Create a Python script to process the YAML
    python3 -c "
import yaml
import sys

source_file = '$source_file'
cluster_name = '$cluster_name'
output_file = '$output_file'

try:
    with open(source_file, 'r') as f:
        config = yaml.safe_load(f)
    
    # Find the specific cluster
    target_cluster = None
    target_context = None
    target_user = None
    
    # Find cluster by name
    for cluster in config.get('clusters', []):
        if cluster.get('name') == cluster_name:
            target_cluster = cluster
            break
    
    if not target_cluster:
        print(f'Cluster {cluster_name} not found in config')
        sys.exit(1)
    
    # Find user by name (same as cluster name)
    for user in config.get('users', []):
        if user.get('name') == cluster_name:
            target_user = user
            break
    
    if not target_user:
        print(f'User {cluster_name} not found in config')
        # Try to find any user with the same name
        for user in config.get('users', []):
            if user.get('name'):
                target_user = user
                break
    
    # Find context by name (same as cluster name)
    for context in config.get('contexts', []):
        if context.get('name') == cluster_name:
            target_context = context
            break
    
    if not target_context:
        # Create a context
        target_context = {
            'name': cluster_name,
            'context': {
                'cluster': cluster_name,
                'user': cluster_name if target_user else 'default'
            }
        }
    
    # Remove certificate-authority-data from cluster
    if 'cluster' in target_cluster and 'certificate-authority-data' in target_cluster['cluster']:
        del target_cluster['cluster']['certificate-authority-data']
    
    # Build new config
    new_config = {
        'apiVersion': 'v1',
        'kind': 'Config',
        'clusters': [target_cluster],
        'users': [target_user] if target_user else [],
        'contexts': [target_context],
        'current-context': cluster_name
    }
    
    # If no user found, create a minimal one
    if not target_user:
        new_config['users'] = [{'name': 'default', 'user': {'token': ''}}]
        new_config['contexts'][0]['context']['user'] = 'default'
    
    with open(output_file, 'w') as f:
        yaml.dump(new_config, f, default_flow_style=False)
    
    print(f'Successfully extracted {cluster_name}')
    
except Exception as e:
    print(f'Error processing config: {e}')
    sys.exit(1)
"
}

# Function to get cluster names from multi-cluster config
get_cluster_names() {
    local source_file="$1"
    
    # Use Python to reliably extract cluster names
    python3 -c "
import yaml
import sys

source_file = '$source_file'

try:
    with open(source_file, 'r') as f:
        config = yaml.safe_load(f)
    
    clusters = config.get('clusters', [])
    for cluster in clusters:
        name = cluster.get('name')
        if name:
            print(name)
    
except Exception as e:
    print(f'Error reading config: {e}')
    sys.exit(1)
"
}

# Function to process single cluster config
process_single_cluster_config() {
    local source_file="$1"
    local filename=$(basename "$source_file")
    filename="${filename%.*}"
    
    # Determine if it's PRD or NPRD based on directory
    local prefix=""
    local display_name="$filename"
    
    # Check if file is in PRD or NPRD directory
    if [[ "$source_file" == */prd/* ]]; then
        prefix="prd_"
        # Remove prd- prefix from filename if present
        display_name="${filename#prd-}"
    elif [[ "$source_file" == */nprd/* ]]; then
        prefix="nprd_"
        # Remove nprd- prefix from filename if present
        display_name="${filename#nprd-}"
    else
        # Determine based on filename
        local lower_name=$(echo "$filename" | tr '[:upper:]' '[:lower:]')
        if [[ "$lower_name" =~ production|prod ]] && [[ ! "$lower_name" =~ non-prod|nonprod|staging|uat|sit|test ]]; then
            prefix="prd_"
        else
            prefix="nprd_"
        fi
    fi
    
    local target_file="$RANCHER_DIR/${prefix}${display_name}"
    
    # Check if file already exists and is up to date
    if [ -f "$target_file" ]; then
        # Compare modification times
        if [ "$source_file" -nt "$target_file" ]; then
            echo -e "${YELLOW}  Updating: $display_name${NC}"
        else
            # File exists and is up to date
            return 0
        fi
    else
        echo -e "${GREEN}  New: $display_name${NC}"
    fi

    # Process the file (remove certificate-authority-data)
    awk '
    BEGIN { skip = 0 }
    /certificate-authority-data:/ {
        skip = 1;
        next
    }
    skip && /^[[:space:]]/ { next }
    skip && /^[^[:space:]]/ { skip = 0 }
    { print }
    ' "$source_file" > "$target_file"

    if [ -f "$target_file" ]; then
        return 0
    else
        return 1
    fi
}

# Function to process multi-cluster kubeconfig
process_multi_cluster_config() {
    local source_file="$1"
    local filename=$(basename "$source_file")
    filename="${filename%.*}"
    
    # Check if Python3 is available
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}Error: python3 is required to process multi-cluster configs${NC}"
        return 1
    fi
    
    # Determine if it's PRD or NPRD based on directory or filename
    local env_type=""
    if [[ "$source_file" == */prd/* ]] || [[ "$filename" =~ ^prd ]]; then
        env_type="prd"
    elif [[ "$source_file" == */nprd/* ]] || [[ "$filename" =~ ^nprd ]]; then
        env_type="nprd"
    else
        # Try to determine from filename
        local lower_name=$(echo "$filename" | tr '[:upper:]' '[:lower:]')
        if [[ "$lower_name" =~ production|prod ]] && [[ ! "$lower_name" =~ non-prod|nonprod|staging|uat|sit|test ]]; then
            env_type="prd"
        else
            env_type="nprd"
        fi
    fi
    
    # Extract all cluster names using Python
    echo -e "${GREEN}  Extracting clusters from multi-cluster config...${NC}"
    
    # Get cluster names
    local clusters=$(get_cluster_names "$source_file")
    local cluster_count=$(echo "$clusters" | wc -l | tr -d ' ')
    
    echo -e "${BLUE}  Found $cluster_count clusters${NC}"
    
    local processed_count=0
    local new_count=0
    
    while IFS= read -r cluster_name; do
        if [ -z "$cluster_name" ]; then
            continue
        fi
        
        local target_file="$RANCHER_DIR/${env_type}_${cluster_name}"
        
        # Check if file already exists and is up to date
        if [ -f "$target_file" ]; then
            # Compare modification times
            if [ "$source_file" -nt "$target_file" ]; then
                echo -e "${YELLOW}    Updating: $cluster_name${NC}"
            else
                # File exists and is up to date
                continue
            fi
        else
            echo -e "${GREEN}    New: $cluster_name${NC}"
            new_count=$((new_count + 1))
        fi
        
        # Extract single cluster from multi-cluster config
        if extract_single_cluster "$source_file" "$cluster_name" "$target_file"; then
            processed_count=$((processed_count + 1))
        else
            echo -e "${RED}    Failed to extract: $cluster_name${NC}"
        fi
    done <<< "$clusters"
    
    echo -e "${GREEN}  Extracted $processed_count clusters ($new_count new)${NC}"
    return 0
}

process_yaml_files() {
    echo -e "${BLUE}Processing YAML files...${NC}"

    # Create rancher_prod directory if it doesn't exist
    if [ ! -d "$RANCHER_DIR" ]; then
        mkdir -p "$RANCHER_DIR"
    fi

    # Check if source directory exists
    if [ ! -d "$SOURCE_YAML_DIR" ]; then
        echo -e "${RED}Error: Source YAML directory not found${NC}"
        return 1
    fi

    local total_processed=0
    local total_new=0
    
    # Process old structure (prd/nprd subdirectories)
    if [ -d "$SOURCE_YAML_DIR/prd" ] || [ -d "$SOURCE_YAML_DIR/nprd" ]; then
        echo -e "${YELLOW}Processing old directory structure (prd/nprd subdirectories)${NC}"
        
        # Process prd directory if it exists
        if [ -d "$SOURCE_YAML_DIR/prd" ]; then
            echo -e "${RED}Checking PRD YAML files...${NC}"
            for source_file in "$SOURCE_YAML_DIR"/prd/*.yaml "$SOURCE_YAML_DIR"/prd/*.yml; do
                if [ -f "$source_file" ]; then
                    filename=$(basename "$source_file")
                    echo -e "${RED}  Processing: $filename${NC}"
                    
                    # Check if it's a multi-cluster config
                    if grep -q "^clusters:" "$source_file" && [ $(python3 -c "
import yaml
import sys
try:
    with open('$source_file', 'r') as f:
        config = yaml.safe_load(f)
    print(len(config.get('clusters', [])))
except:
    print('0')
" 2>/dev/null) -gt 1 ]; then
                        echo -e "${GREEN}    Detected multi-cluster kubeconfig${NC}"
                        if process_multi_cluster_config "$source_file"; then
                            total_processed=$((total_processed + 1))
                        fi
                    else
                        # Process as single cluster config
                        if process_single_cluster_config "$source_file"; then
                            total_processed=$((total_processed + 1))
                        fi
                    fi
                fi
            done
        fi
        
        # Process nprd directory if it exists
        if [ -d "$SOURCE_YAML_DIR/nprd" ]; then
            echo -e "${BLUE}Checking NPRD YAML files...${NC}"
            for source_file in "$SOURCE_YAML_DIR"/nprd/*.yaml "$SOURCE_YAML_DIR"/nprd/*.yml; do
                if [ -f "$source_file" ]; then
                    filename=$(basename "$source_file")
                    echo -e "${BLUE}  Processing: $filename${NC}"
                    
                    # Check if it's a multi-cluster config
                    if grep -q "^clusters:" "$source_file" && [ $(python3 -c "
import yaml
import sys
try:
    with open('$source_file', 'r') as f:
        config = yaml.safe_load(f)
    print(len(config.get('clusters', [])))
except:
    print('0')
" 2>/dev/null) -gt 1 ]; then
                        echo -e "${GREEN}    Detected multi-cluster kubeconfig${NC}"
                        if process_multi_cluster_config "$source_file"; then
                            total_processed=$((total_processed + 1))
                        fi
                    else
                        # Process as single cluster config
                        if process_single_cluster_config "$source_file"; then
                            total_processed=$((total_processed + 1))
                        fi
                    fi
                fi
            done
        fi
    fi
    
    # Process root directory (for backward compatibility)
    echo -e "${BLUE}Processing files in root directory...${NC}"
    
    for source_file in "$SOURCE_YAML_DIR"/*.yaml "$SOURCE_YAML_DIR"/*.yml; do
        if [ -f "$source_file" ] && [[ ! "$source_file" == */prd/* ]] && [[ ! "$source_file" == */nprd/* ]]; then
            filename=$(basename "$source_file")
            echo -e "${BLUE}Processing: $filename${NC}"
            
            # Check if it's a multi-cluster config
            if grep -q "^clusters:" "$source_file" && [ $(python3 -c "
import yaml
import sys
try:
    with open('$source_file', 'r') as f:
        config = yaml.safe_load(f)
    print(len(config.get('clusters', [])))
except:
    print('0')
" 2>/dev/null) -gt 1 ]; then
                echo -e "${GREEN}  Detected multi-cluster kubeconfig${NC}"
                if process_multi_cluster_config "$source_file"; then
                    total_processed=$((total_processed + 1))
                fi
            else
                # Process as single cluster config
                echo -e "${GREEN}  Processing as single cluster config${NC}"
                if process_single_cluster_config "$source_file"; then
                    total_processed=$((total_processed + 1))
                fi
            fi
        fi
    done
    
    if [ $total_processed -eq 0 ]; then
        echo -e "${YELLOW}No YAML files found to process${NC}"
    else
        echo -e "${GREEN}Total: $total_processed files/clusters processed${NC}"
    fi
    
    return 0
}

# ============================================
# Helper: extract actual cluster/context name from kubeconfig YAML
# ============================================

get_actual_cluster_name() {
    local file="$1"
    local name=""

    # Try to extract context name (most user-friendly)
    name=$(awk '
        /^\s*contexts:\s*$/ { in_ctx=1; next }
        in_ctx && /^\s*-?\s*name:\s*/ { gsub(/^[ \t-]*name:[ \t]*/,""); print; exit }
    ' "$file" 2>/dev/null)

    if [ -n "$name" ]; then
        # strip quotes if present
        name="${name%\"}"
        name="${name#\"}"
        name="${name%\'}"
        name="${name#\'}"
        echo "$name"
        return
    fi

    # Try to extract clusters.name
    name=$(awk '
        /^\s*clusters:\s*$/ { in_cluster=1; next }
        in_cluster && /^\s*-?\s*name:\s*/ { gsub(/^[ \t-]*name:[ \t]*/,""); print; exit }
    ' "$file" 2>/dev/null)

    if [ -n "$name" ]; then
        name="${name%\"}"
        name="${name#\"}"
        name="${name%\'}"
        name="${name#\'}"
        echo "$name"
        return
    fi

    # Fallback: current-context
    name=$(awk '/^\s*current-context:\s*/ { gsub(/^[ \t]*current-context:[ \t]*/,""); print; exit }' "$file" 2>/dev/null)
    if [ -n "$name" ]; then
        name="${name%\"}"
        name="${name#\"}"
        name="${name%\'}"
        name="${name#\'}"
        echo "$name"
        return
    fi

    # If nothing found, return filename without prefix
    name=$(basename "$file")
    name="${name#prd_}"
    name="${name#nprd_}"
    echo "$name"
}

# ============================================
# Environment Detection Functions
# ============================================

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
    # Remove prd_ or nprd_ prefix for display if present
    name="${name#prd_}"
    name="${name#nprd_}"
    echo "$name"
}

# ============================================
# Terminal Functions
# ============================================

get_terminal_width() {
    tput cols 2>/dev/null || echo 80
}

# ============================================
# CLUSTER DISPLAY
# ============================================

show_current_context() {
    if [ -f "$MAIN_CONFIG" ]; then
        current_ctx=$(kubectl config current-context 2>/dev/null || echo "None")
        echo -e "${GRAY}Current: ${WHITE}$current_ctx${NC}"
    else
        echo -e "${GRAY}Current: ${RED}None${NC}"
    fi
}

get_all_clusters() {
    # Global arrays for each environment type
    PRD_CLUSTERS=()
    SIT_CLUSTERS=()
    UAT_CLUSTERS=()
    TEST_CLUSTERS=()
    OTHER_CLUSTERS=()
    
    while IFS= read -r file; do
        if [ -f "$file" ]; then
            filename=$(basename "$file")
            actual_name=$(get_actual_cluster_name "$file")
            name="${actual_name:-$filename}"
            env_type=$(get_environment_type "$name")
            
            # Add to appropriate array
            case $env_type in
                "PRD")
                    PRD_CLUSTERS+=("$file")
                    ;;
                "SIT")
                    SIT_CLUSTERS+=("$file")
                    ;;
                "UAT")
                    UAT_CLUSTERS+=("$file")
                    ;;
                "TEST")
                    TEST_CLUSTERS+=("$file")
                    ;;
                *)
                    OTHER_CLUSTERS+=("$file")
                    ;;
            esac
        fi
    done < <(find "$RANCHER_DIR" -maxdepth 1 \( -name "*.yaml" -o -name "*.yml" -o -name "*" \) 2>/dev/null | sort)
}

# ============================================
# TABLE FORMAT DISPLAY - Grouped by Environment
# ============================================

display_environment_clusters() {
    local env_name="$1"
    local clusters_array_name="$2"
    local start_number="$3"
    
    # Get the array indirectly
    eval "local clusters_array=(\"\${$clusters_array_name[@]}\")"
    local total=${#clusters_array[@]}
    
    if [ $total -eq 0 ]; then
        return
    fi
    
    local per_col=$(( (total + 1) / 2 ))
    local col_width=45
    
    for ((i=0; i<per_col; i++)); do
        # Column 1
        idx1=$i
        line1=""
        if [ $idx1 -lt $total ]; then
            cluster_path="${clusters_array[$idx1]}"
            actual_name=$(get_actual_cluster_name "$cluster_path")
            name="${actual_name:-$(basename "$cluster_path")}"
            display_name=$(format_cluster_name "$name")
            
            # Truncate if too long
            if [ ${#display_name} -gt 35 ]; then
                display_name="${display_name:0:32}..."
            fi
            
            number=$((start_number + idx1))
            env_color=$(get_environment_color "$env_name")
            line1=$(printf "  ${env_color}%3d) [${env_name}] %-${col_width}s${NC}" "$number" "$display_name")
        else
            line1=$(printf "  %-${col_width}s" "")
        fi
        
        # Column 2
        idx2=$((i + per_col))
        line2=""
        if [ $idx2 -lt $total ]; then
            cluster_path="${clusters_array[$idx2]}"
            actual_name=$(get_actual_cluster_name "$cluster_path")
            name="${actual_name:-$(basename "$cluster_path")}"
            display_name=$(format_cluster_name "$name")
            
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
    clear
    echo -e "${BLUE}K9S CLUSTER MANAGER${NC}"
    show_current_context
    echo ""

    get_all_clusters
    
    local total_prd=${#PRD_CLUSTERS[@]}
    local total_sit=${#SIT_CLUSTERS[@]}
    local total_uat=${#UAT_CLUSTERS[@]}
    local total_test=${#TEST_CLUSTERS[@]}
    local total_other=${#OTHER_CLUSTERS[@]}
    local total_clusters=$((total_prd + total_sit + total_uat + total_test + total_other))

    if [ $total_clusters -eq 0 ]; then
        echo -e "${YELLOW}No clusters found${NC}"
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
    echo -e "${BLUE}│           NON-PRODUCTION CLUSTERS                 │${NC}"
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
    file_name=$(basename "$cluster_path")
    actual_name=$(get_actual_cluster_name "$cluster_path")
    display_name=$(format_cluster_name "${actual_name:-$file_name}")

    echo ""
    echo -e "${BLUE}────────────────────────────────────────────${NC}"
    echo -e "${BLUE}Switching to: ${WHITE}$display_name${NC}"
    echo -e "${BLUE}────────────────────────────────────────────${NC}"

    if [ -f "$MAIN_CONFIG" ]; then
        cp "$MAIN_CONFIG" "$BACKUP_DIR/config.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    cp "$cluster_path" "$MAIN_CONFIG"
    export KUBECONFIG="$MAIN_CONFIG"

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
# MANUAL CLUSTER SEARCH WITH BACK OPTION
# ============================================

manual_search_cluster() {
    while true; do
        clear
        echo -e "${BLUE}K9S CLUSTER MANAGER - SEARCH${NC}"
        show_current_context
        echo ""
        echo -e "${BLUE}Enter cluster name (partial allowed, or 'b' to go back):${NC}"
        read -r search

        # Check if user wants to go back
        if [[ "$search" == "b" || "$search" == "B" ]]; then
            return
        fi

        get_all_clusters
        # Combine all clusters for search
        ALL_CLUSTERS_LIST=()
        for cluster in "${PRD_CLUSTERS[@]}"; do ALL_CLUSTERS_LIST+=("$cluster"); done
        for cluster in "${SIT_CLUSTERS[@]}"; do ALL_CLUSTERS_LIST+=("$cluster"); done
        for cluster in "${UAT_CLUSTERS[@]}"; do ALL_CLUSTERS_LIST+=("$cluster"); done
        for cluster in "${TEST_CLUSTERS[@]}"; do ALL_CLUSTERS_LIST+=("$cluster"); done
        for cluster in "${OTHER_CLUSTERS[@]}"; do ALL_CLUSTERS_LIST+=("$cluster"); done

        matches=()
        for c in "${ALL_CLUSTERS_LIST[@]}"; do
            actual_name=$(get_actual_cluster_name "$c")
            file_name=$(basename "$c")
            name="${actual_name:-$file_name}"
            lower_name=$(echo "$name" | tr '[:upper:]' '[:lower:]')
            lower_search=$(echo "$search" | tr '[:upper:]' '[:lower:]')
            if [[ "$lower_name" == *"$lower_search"* ]]; then
                matches+=("$c")
            fi
        done

        if [ ${#matches[@]} -eq 0 ]; then
            echo ""
            echo -e "${RED}No matching clusters found${NC}"
            sleep 2
            continue
        fi

        clear
        echo -e "${BLUE}K9S CLUSTER MANAGER - SEARCH RESULTS${NC}"
        show_current_context
        echo ""
        echo -e "${GREEN}Found ${#matches[@]} matching cluster(s):${NC}"
        echo ""

        i=1
        for m in "${matches[@]}"; do
            actual_name=$(get_actual_cluster_name "$m")
            file_name=$(basename "$m")
            name="${actual_name:-$file_name}"
            env_type=$(get_environment_type "$name")
            env_color=$(get_environment_color "$env_type")
            display_name=$(format_cluster_name "$name")
            
            # Truncate if too long
            if [ ${#display_name} -gt 50 ]; then
                display_name="${display_name:0:47}..."
            fi
            
            echo -e "  ${env_color}$i) [${env_type}] ${display_name}${NC}"
            i=$((i+1))
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
            b|B)
                continue  # Go back to search prompt
                ;;
            m|M)
                return  # Go back to main menu
                ;;
            [1-9]|[1-9][0-9])
                local idx=$((pick-1))
                if [ $idx -lt ${#matches[@]} ]; then
                    chosen="${matches[$idx]}"
                    switch_to_cluster "$chosen"
                    launch_k9s
                    return  # Return to main menu after launching k9s
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
            echo -n -e "${BLUE}Select option (r/f/q): ${NC}"
        else
            get_all_clusters
            total_prd=${#PRD_CLUSTERS[@]}
            total_sit=${#SIT_CLUSTERS[@]}
            total_uat=${#UAT_CLUSTERS[@]}
            total_test=${#TEST_CLUSTERS[@]}
            total_other=${#OTHER_CLUSTERS[@]}
            total_clusters=$((total_prd + total_sit + total_uat + total_test + total_other))
            echo -n -e "${BLUE}Select (1-$total_clusters/r/f/q): ${NC}"
        fi

        read -r choice

        case $choice in
            [1-9]|[1-9][0-9]|[1-9][0-9][0-9])
                local idx=$((choice-1))
                # Combine all clusters for selection
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
# STARTUP - NO MANUAL KEY PRESSES
# ============================================

clear
echo -e "${BLUE}K9S CLUSTER SWITCHER${NC}"
echo ""

# Always check for new YAML files on startup
echo -e "${BLUE}Checking for new or updated YAML files...${NC}"
process_yaml_files

sleep 1
clear

main_loop
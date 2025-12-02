#!/bin/bash

# ============================================
# K9S CLUSTER SWITCHER - AUTO LOAD
# ============================================

# Configuration
RANCHER_DIR="${HOME}/.kube/rancher_prod"
MAIN_CONFIG="${HOME}/.kube/config"
BACKUP_DIR="${HOME}/.kube/backups"
SOURCE_YAML_DIR="./YAML"
SETUP_FLAG_FILE="${HOME}/.kube/rancher_prod_setup_complete"

# Colors
BLUE='\033[38;5;39m'
GREEN='\033[38;5;46m'
YELLOW='\033[38;5;226m'
ORANGE='\033[38;5;214m'
RED='\033[38;5;196m'
PURPLE='\033[38;5;129m'
GRAY='\033[38;5;245m'
WHITE='\033[38;5;255m'
NC='\033[0m'

# Ensure directories exist
mkdir -p "$BACKUP_DIR"

# ============================================
# SETUP FUNCTIONS
# ============================================

setup_initial_config() {
    clear
    
    # Create rancher_prod directory
    if [ ! -d "$RANCHER_DIR" ]; then
        mkdir -p "$RANCHER_DIR"
    fi
    
    # Check if source directory exists
    if [ ! -d "$SOURCE_YAML_DIR" ]; then
        echo -e "${RED}Error: Source YAML directory not found${NC}"
        exit 1
    fi
    
    yaml_count=$(find "$SOURCE_YAML_DIR" -maxdepth 1 \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null | wc -l | tr -d ' ')
    
    if [ $yaml_count -eq 0 ]; then
        echo -e "${YELLOW}No YAML files found${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Processing $yaml_count YAML files...${NC}"
    
    processed_count=0
    for source_file in "$SOURCE_YAML_DIR"/*.yaml "$SOURCE_YAML_DIR"/*.yml; do
        if [ -f "$source_file" ]; then
            filename=$(basename "$source_file")
            
            awk '
            BEGIN { skip = 0 }
            /certificate-authority-data:/ { 
                skip = 1; 
                next 
            }
            skip && /^[[:space:]]/ { next }
            skip && /^[^[:space:]]/ { skip = 0 }
            { print }
            ' "$source_file" > "$RANCHER_DIR/$filename"
            
            if [ -f "$RANCHER_DIR/$filename" ]; then
                processed_count=$((processed_count + 1))
            fi
        fi
    done
    
    echo -e "${GREEN}Setup complete! $processed_count files processed${NC}"
    touch "$SETUP_FLAG_FILE"
    sleep 1
    clear
}

install_k9s_with_brew() {
    echo -e "\n${BLUE}Installing k9s via Homebrew...${NC}"
    
    if ! command -v brew &> /dev/null; then
        echo -e "${RED}Homebrew not installed${NC}"
        exit 1
    fi
    
    brew update > /dev/null 2>&1
    brew install k9s > /dev/null 2>&1
    echo -e "${GREEN}k9s installed${NC}"
    sleep 1
}

check_and_install_k9s() {
    if ! command -v k9s &> /dev/null; then
        echo -e "${YELLOW}k9s not installed${NC}"
        install_k9s_with_brew
    fi
}

# ============================================
# UI FUNCTIONS
# ============================================

get_terminal_width() {
    tput cols 2>/dev/null || echo 100
}

get_environment_color() {
    local name="$1"
    local lower_name=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    
    if [[ $lower_name =~ production|prod ]] && [[ ! $lower_name =~ non-prod|nonprod|staging|uat|sit|test ]]; then
        echo "$RED"
    elif [[ $lower_name =~ staging|stage ]]; then
        echo "$ORANGE"
    elif [[ $lower_name =~ uat|useracceptance ]]; then
        echo "$PURPLE"
    elif [[ $lower_name =~ sit|systemintegration ]]; then
        echo "$GREEN"
    elif [[ $lower_name =~ test|testing ]]; then
        echo "$YELLOW"
    elif [[ $lower_name =~ dev|development ]]; then
        echo "$BLUE"
    elif [[ $lower_name =~ perf|performance|load ]]; then
        echo "$PURPLE"
    else
        echo "$WHITE"
    fi
}

get_environment_tag() {
    local name="$1"
    local lower_name=$(echo "$name" | tr '[:upper:]' '[:lower:]')
    
    if [[ $lower_name =~ production|prod ]]; then
        echo "[PROD]"
    elif [[ $lower_name =~ staging|stage ]]; then
        echo "[STAGE]"
    elif [[ $lower_name =~ uat|useracceptance ]]; then
        echo "[UAT]"
    elif [[ $lower_name =~ sit|systemintegration ]]; then
        echo "[SIT]"
    elif [[ $lower_name =~ test|testing ]]; then
        echo "[TEST]"
    elif [[ $lower_name =~ dev|development ]]; then
        echo "[DEV]"
    elif [[ $lower_name =~ perf|performance|load ]]; then
        echo "[PERF]"
    else
        echo "[OTHER]"
    fi
}

format_cluster_name() {
    local name="$1"
    name="${name%.*}"
    echo "$name" | sed -e 's/[_-]/ /g' -e 's/ v5 / V5 /g' -e 's/ v1 / V1 /g' -e 's/\bv5\b/V5/g' -e 's/\bv1\b/V1/g'
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
    clusters=()
    while IFS= read -r file; do
        if [ -f "$file" ]; then
            clusters+=("$file")
        fi
    done < <(find "$RANCHER_DIR" -maxdepth 1 \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null | sort)
}

calculate_column_width() {
    local clusters=("$@")
    local max_length=0
    
    for cluster in "${clusters[@]}"; do
        cluster_name=$(basename "$cluster")
        display_name=$(format_cluster_name "$cluster_name")
        tag=$(get_environment_tag "$cluster_name")
        
        local length=$(( ${#tag} + ${#display_name} + 5 ))
        if [ $length -gt $max_length ]; then
            max_length=$length
        fi
    done
    
    echo $max_length
}

show_optimized_menu() {
    clear
    echo -e "${BLUE}K9S CLUSTER MANAGER${NC}"
    show_current_context
    echo ""
    
    get_all_clusters
    local total_clusters=${#clusters[@]}
    
    if [ $total_clusters -eq 0 ]; then
        echo -e "${YELLOW}No clusters found${NC}"
        return 1
    fi
    
    # Calculate optimal layout
    local terminal_width=$(get_terminal_width)
    local col_width=$(calculate_column_width "${clusters[@]}")
    local clusters_per_col=$(( (total_clusters + 1) / 2 ))
    
    # Adjust column width based on terminal size
    if [ $((col_width * 2 + 8)) -gt $terminal_width ]; then
        col_width=$(( (terminal_width - 8) / 2 ))
    fi
    
    echo -e "${WHITE}Available Clusters:${NC}"
    echo ""
    
    # Display in two columns
    for ((i=0; i<clusters_per_col; i++)); do
        # Left column
        idx1=$i
        if [ $idx1 -lt $total_clusters ]; then
            cluster_path="${clusters[$idx1]}"
            cluster_name=$(basename "$cluster_path")
            display_name=$(format_cluster_name "$cluster_name")
            tag=$(get_environment_tag "$cluster_name")
            color=$(get_environment_color "$cluster_name")
            number=$((idx1 + 1))
            
            printf "  ${color}%2d) ${tag} %-${col_width}s${NC}" "$number" "$display_name"
        fi
        
        # Right column
        idx2=$((i + clusters_per_col))
        if [ $idx2 -lt $total_clusters ]; then
            cluster_path="${clusters[$idx2]}"
            cluster_name=$(basename "$cluster_path")
            display_name=$(format_cluster_name "$cluster_name")
            tag=$(get_environment_tag "$cluster_name")
            color=$(get_environment_color "$cluster_name")
            number=$((idx2 + 1))
            
            printf "  ${color}%2d) ${tag} %s${NC}" "$number" "$display_name"
        fi
        
        echo ""
    done
    
    echo ""
    echo -e "${BLUE}────────────────────────────────────────────────────────────────────${NC}"
    echo -e "${GRAY}Total: ${WHITE}$total_clusters${GRAY} clusters${NC}"
    echo ""
    
    # Navigation menu
    echo -e "${WHITE}Navigation:${NC}"
    echo ""
    echo -e "  ${GREEN}1-$total_clusters${WHITE}  Select cluster"
    echo -e "  ${YELLOW}r${WHITE}            Refresh list"
    echo -e "  ${BLUE}s${WHITE}            Run setup"
    echo -e "  ${PURPLE}k${WHITE}            Install k9s"
    echo -e "  ${RED}q${WHITE}            Quit"
    echo ""
}

# ============================================
# CLUSTER OPERATIONS
# ============================================

switch_to_cluster() {
    local cluster_path="$1"
    local cluster_name=$(basename "$cluster_path")
    local display_name=$(format_cluster_name "$cluster_name")
    
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
# MAIN LOOP
# ============================================

main_loop() {
    while true; do
        show_optimized_menu
        
        if [ $? -ne 0 ]; then
            echo -n -e "${BLUE}Select option (r/s/k/q): ${NC}"
        else
            echo -n -e "${BLUE}Select (1-${#clusters[@]}/r/s/k/q): ${NC}"
        fi
        
        read -r choice
        
        case $choice in
            [1-9]|[1-9][0-9])
                local idx=$((choice-1))
                if [ -n "${clusters[$idx]}" ]; then
                    switch_to_cluster "${clusters[$idx]}"
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
            s|S)
                setup_initial_config
                ;;
            k|K)
                check_and_install_k9s
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

# Check and install k9s if needed
check_and_install_k9s

# Check if setup needs to run
if [ ! -f "$SETUP_FLAG_FILE" ] || [ ! -d "$RANCHER_DIR" ] || [ $(find "$RANCHER_DIR" -maxdepth 1 \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null | wc -l) -eq 0 ]; then
    echo -e "${BLUE}Running first-time setup...${NC}"
    setup_initial_config
else
    cluster_count=$(find "$RANCHER_DIR" -maxdepth 1 \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null | wc -l | tr -d ' ')
    echo -e "${GREEN}Loaded $cluster_count clusters${NC}"
    sleep 0.5
    clear
fi

# Start main loop
main_loop
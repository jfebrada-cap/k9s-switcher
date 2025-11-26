#!/bin/bash

# Simple Vertical List k9s Cluster Switcher
RANCHER_DIR="${HOME}/.kube/rancher_prod"
MAIN_CONFIG="${HOME}/.kube/config"
BACKUP_DIR="${HOME}/.kube/backups"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
ORANGE='\033[0;33m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Symbols
ARROW="➤"
CHECK="✅"
ROCKET="🚀"
CLUSTER="🎯"
EXIT="🚪"
REFRESH="🔄"
BACK="↩️"

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

show_current_context() {
    if [ -f "$MAIN_CONFIG" ]; then
        current_ctx=$(kubectl config current-context 2>/dev/null || echo "None")
        echo -e "${CYAN}📋 Current Context: ${GREEN}$current_ctx${NC}"
    else
        echo -e "${YELLOW}📋 Current Context: ${RED}None${NC}"
    fi
}

get_all_clusters() {
    clusters=()
    for file in "$RANCHER_DIR"/*.yaml "$RANCHER_DIR"/*.yml; do
        if [ -f "$file" ]; then
            clusters+=("$file")
        fi
    done
}

create_cluster_map() {
    cluster_map=()
    local counter=1
    
    for cluster in "${clusters[@]}"; do
        cluster_map[$counter]="$cluster"
        counter=$((counter + 1))
    done
}

show_simple_menu() {
    clear
    
    # Get all clusters
    get_all_clusters
    
    # Create the cluster mapping
    create_cluster_map
    
    show_current_context
    echo ""
    
    echo -e "${WHITE}${CLUSTER} Available Clusters:${NC}"
    echo ""
    
    if [ ${#clusters[@]} -eq 0 ]; then
        echo -e "${RED}❌ No cluster files found in: $RANCHER_DIR${NC}"
        exit 1
    fi
    
    # Simple numbered list
    for i in "${!clusters[@]}"; do
        cluster_path="${clusters[$i]}"
        cluster_name=$(basename "$cluster_path")
        display_name="${cluster_name%.*}"
        
        # Color code based on environment
        lower_name=$(echo "$cluster_name" | tr '[:upper:]' '[:lower:]')
        
        if [[ $lower_name =~ production|prod ]] && [[ ! $lower_name =~ non-prod|nonprod|staging|uat|sit|test ]]; then
            color=$RED
            env="[PROD]"
        elif [[ $lower_name =~ uat|useracceptance ]]; then
            color=$CYAN
            env="[UAT] "
        elif [[ $lower_name =~ sit|systemintegration ]]; then
            color=$GREEN
            env="[SIT] "
        elif [[ $lower_name =~ test|testing ]] && [[ ! $lower_name =~ production|prod ]]; then
            color=$YELLOW
            env="[TEST]"
        elif [[ $lower_name =~ perf|performance|load ]]; then
            color=$ORANGE
            env="[PERF]"
        else
            color=$WHITE
            env="[OTHER]"
        fi
        
        number=$((i + 1))
        printf "  ${color}%2d) ${env} %s${NC}\n" "$number" "$display_name"
    done
    
    echo ""
    echo -e "${CYAN}📊 Total clusters available: ${GREEN}${#clusters[@]}${NC}"
    echo ""
    
    echo -e "${WHITE}${ARROW} Navigation:${NC}"
    echo -e "  ${GREEN}1-${#clusters[@]}${WHITE} - Select cluster and launch k9s"
    echo -e "  ${YELLOW}r${WHITE}     - Refresh cluster list"
    echo -e "  ${RED}q${WHITE}     - Quit"
    echo ""
}

switch_to_cluster() {
    cluster_path="$1"
    cluster_name=$(basename "$cluster_path")
    
    echo -e "\n${YELLOW}${REFRESH} Switching to: ${WHITE}$cluster_name${NC}"
    
    # Backup current config
    if [ -f "$MAIN_CONFIG" ]; then
        cp "$MAIN_CONFIG" "$BACKUP_DIR/config.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Switch cluster
    cp "$cluster_path" "$MAIN_CONFIG"
    export KUBECONFIG="$MAIN_CONFIG"
    
    # Test connection
    echo -e "${CYAN}🔍 Testing connection...${NC}"
    if kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
        echo -e "${GREEN}${CHECK} Cluster connection successful${NC}"
    else
        echo -e "${YELLOW}⚠️  Cluster may be offline or require VPN${NC}"
    fi
    
    new_context=$(kubectl config current-context 2>/dev/null || echo "unknown")
    echo -e "${GREEN}${CHECK} Now connected to: ${WHITE}$new_context${NC}"
}

launch_k9s() {
    echo -e "\n${ROCKET} ${GREEN}Launching k9s...${NC}"
    echo -e "${YELLOW}💡 Tip: Press '0' to return to this menu${NC}"
    echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
    
    k9s
    
    echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}${BACK} Welcome back! Select another cluster or exit.${NC}"
    echo ""
}

main_loop() {
    while true; do
        show_simple_menu
        
        if [ ${#cluster_map[@]} -eq 0 ]; then
            echo -e "${RED}❌ No clusters available. Check your Rancher directory.${NC}"
            exit 1
        fi
        
        echo -n -e "${CYAN}${ARROW} Your choice (1-${#cluster_map[@]}, r, q): ${NC}"
        read choice
        
        case $choice in
            [1-9]|[1-9][0-9])
                if [ -n "${cluster_map[$choice]}" ]; then
                    selected_cluster="${cluster_map[$choice]}"
                    switch_to_cluster "$selected_cluster"
                    launch_k9s
                else
                    echo -e "${RED}❌ Invalid selection. Please try again.${NC}"
                    sleep 1
                fi
                ;;
            r|R)
                echo -e "${YELLOW}${REFRESH} Refreshing cluster list...${NC}"
                sleep 1
                ;;
            q|Q)
                echo -e "${GREEN}${EXIT} Thank you for using k9s Cluster Manager!${NC}"
                echo ""
                exit 0
                ;;
            *)
                echo -e "${RED}❌ Invalid choice. Please enter a number (1-${#cluster_map[@]}), 'r', or 'q'.${NC}"
                sleep 1.5
                ;;
        esac
    done
}

# Check if rancher directory exists
if [ ! -d "$RANCHER_DIR" ]; then
    echo -e "${RED}❌ Rancher directory not found: $RANCHER_DIR${NC}"
    echo -e "${YELLOW}Please check if the directory exists and contains your cluster configs${NC}"
    exit 1
fi

# Check if k9s is installed
if ! command -v k9s &> /dev/null; then
    echo -e "${RED}❌ k9s is not installed. Please install k9s first.${NC}"
    exit 1
fi

# Global variables
cluster_map=()

# Start the main loop
main_loop
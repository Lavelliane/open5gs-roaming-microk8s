#!/bin/bash

# K8s Pod Manager - A simple CLI for managing Kubernetes pods
# Usage: ./k8s-pod-manager.sh [namespace]

# Color definitions
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Default namespace
NAMESPACE="open5gs"

# Check if microk8s is installed
if ! command -v microk8s &> /dev/null; then
    echo -e "${RED}Error: microk8s is not installed or not in your PATH${NC}"
    exit 1
fi

# Check for namespace parameter
if [ "$1" != "" ]; then
    NAMESPACE="$1"
fi

# Function to get pods
get_pods() {
    echo -e "${BLUE}Fetching pods in namespace $NAMESPACE...${NC}"
    PODS=$(microk8s kubectl get pods -n $NAMESPACE --no-headers | awk '{print $1}')
    
    if [ -z "$PODS" ]; then
        echo -e "${RED}No pods found in namespace $NAMESPACE${NC}"
        exit 1
    fi
    
    # Create array of pods
    PODS_ARRAY=($PODS)
    echo -e "${GREEN}Found ${#PODS_ARRAY[@]} pods${NC}"
}

# Function to display pod menu
show_pod_menu() {
    echo -e "\n${YELLOW}Select a pod:${NC}"
    for i in "${!PODS_ARRAY[@]}"; do
        STATUS=$(microk8s kubectl get pod ${PODS_ARRAY[$i]} -n $NAMESPACE --no-headers | awk '{print $3}')
        READY=$(microk8s kubectl get pod ${PODS_ARRAY[$i]} -n $NAMESPACE --no-headers | awk '{print $2}')
        echo -e "$((i+1)). ${PODS_ARRAY[$i]} - Status: $STATUS, Ready: $READY"
    done
    echo -e "0. Exit"
    
    read -p "Enter pod number: " POD_NUMBER
    
    if [ "$POD_NUMBER" -eq 0 ]; then
        echo -e "${BLUE}Exiting...${NC}"
        exit 0
    fi
    
    if [ "$POD_NUMBER" -lt 1 ] || [ "$POD_NUMBER" -gt ${#PODS_ARRAY[@]} ]; then
        echo -e "${RED}Invalid selection${NC}"
        show_pod_menu
        return
    fi
    
    SELECTED_POD=${PODS_ARRAY[$((POD_NUMBER-1))]}
    echo -e "${GREEN}Selected pod: $SELECTED_POD${NC}"
    show_action_menu
}

# Function to display action menu
show_action_menu() {
    echo -e "\n${YELLOW}Actions for pod $SELECTED_POD:${NC}"
    echo -e "1. Exec into pod (bash shell)"
    echo -e "2. Exec custom command"
    echo -e "3. View logs"
    echo -e "4. Restart pod"
    echo -e "5. Delete pod"
    echo -e "0. Back to pod selection"
    
    read -p "Enter action number: " ACTION_NUMBER
    
    case $ACTION_NUMBER in
        0)
            show_pod_menu
            ;;
        1)
            echo -e "${BLUE}Executing bash shell in $SELECTED_POD...${NC}"
            microk8s kubectl exec -it $SELECTED_POD -n $NAMESPACE -- /bin/bash || microk8s kubectl exec -it $SELECTED_POD -n $NAMESPACE -- /bin/sh
            show_action_menu
            ;;
        2)
            read -p "Enter command to execute: " CUSTOM_COMMAND
            echo -e "${BLUE}Executing command in $SELECTED_POD: $CUSTOM_COMMAND${NC}"
            microk8s kubectl exec -it $SELECTED_POD -n $NAMESPACE -- $CUSTOM_COMMAND
            show_action_menu
            ;;
        3)
            echo -e "${BLUE}Showing logs for $SELECTED_POD...${NC}"
            microk8s kubectl logs $SELECTED_POD -n $NAMESPACE
            read -p "Press enter to continue..."
            show_action_menu
            ;;
        4)
            echo -e "${YELLOW}Restarting pod $SELECTED_POD...${NC}"
            microk8s kubectl delete pod $SELECTED_POD -n $NAMESPACE
            echo -e "${GREEN}Pod $SELECTED_POD deleted. If managed by a controller, it will be recreated.${NC}"
            sleep 2
            get_pods
            show_pod_menu
            ;;
        5)
            echo -e "${RED}Are you sure you want to delete pod $SELECTED_POD? (y/N)${NC}"
            read -p "" CONFIRM
            if [[ $CONFIRM =~ ^[Yy]$ ]]; then
                microk8s kubectl delete pod $SELECTED_POD -n $NAMESPACE
                echo -e "${GREEN}Pod $SELECTED_POD deleted.${NC}"
                sleep 2
                get_pods
                show_pod_menu
            else
                echo -e "${BLUE}Deletion cancelled.${NC}"
                show_action_menu
            fi
            ;;
        *)
            echo -e "${RED}Invalid selection${NC}"
            show_action_menu
            ;;
    esac
}

# Main function
main() {
    echo -e "${BLUE}K8s Pod Manager - Namespace: $NAMESPACE${NC}"
    get_pods
    show_pod_menu
}

main
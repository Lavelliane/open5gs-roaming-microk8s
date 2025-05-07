#!/bin/bash

# Script to debug Multus network connectivity between 5G Core components
# Created: May 2025

# Exit on error
set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default namespace
NAMESPACE="open5gs"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace|-n)
      NAMESPACE="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--namespace|-n NAMESPACE]"
      echo "  --namespace, -n: Specify the namespace to check (default: open5gs)"
      echo "  --help, -h: Display this help message"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
  esac
done

echo -e "${BLUE}5G Core Network Connectivity Debug Tool${NC}"
echo -e "${BLUE}Namespace: $NAMESPACE${NC}"
echo "----------------------------------------"

# Check if Multus is installed
echo -e "${YELLOW}Checking for Multus CNI...${NC}"
if ! microk8s kubectl get customresourcedefinition network-attachment-definitions.k8s.cni.cncf.io &>/dev/null; then
  echo -e "${RED}Error: Multus CNI not installed. Please run setup-multus.sh first.${NC}"
  exit 1
fi
echo -e "${GREEN}Multus CNI is installed.${NC}"

# Check network attachment definitions
echo -e "${YELLOW}Checking network attachment definitions...${NC}"
microk8s kubectl get networkattachmentdefinition -n $NAMESPACE
echo "----------------------------------------"

# Function to get pod interfaces
get_pod_interfaces() {
    local pod=$1
    local interfaces=""
    
    echo -e "${BLUE}Interfaces for pod: $pod${NC}"
    
    # Check if pod exists
    if ! microk8s kubectl get pod -n $NAMESPACE $pod &>/dev/null; then
        echo -e "${RED}Error: Pod $pod not found${NC}"
        return 1
    fi
    
    # Get pod interfaces
    echo -e "${YELLOW}Interface list:${NC}"
    microk8s kubectl exec -n $NAMESPACE $pod -- ip -o link show | awk -F': ' '{print $2}'
    
    # Get IP addresses for each interface
    echo -e "${YELLOW}IP addresses:${NC}"
    microk8s kubectl exec -n $NAMESPACE $pod -- ip -4 -o addr show | grep -v "scope host" | grep -v "scope link" | grep -v "virbr"
    
    echo "----------------------------------------"
}

# Get a list of pods
echo -e "${YELLOW}Getting pods in namespace $NAMESPACE...${NC}"
PODS=$(microk8s kubectl get pods -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}')

# Check SMF and UPF connectivity (most critical for PFCP)
SMF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-smf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
UPF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-upf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
AMF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-amf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
PR_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=packetrusher -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

# Check SMF interfaces
if [ ! -z "$SMF_POD" ]; then
    echo -e "${BLUE}Checking SMF pod: $SMF_POD${NC}"
    get_pod_interfaces $SMF_POD
    
    # Get SMF PFCP IP
    SMF_PFCP_IP=$(microk8s kubectl exec -n $NAMESPACE $SMF_POD -- ip -4 -o addr show | grep -oP 'pfcp.*(?<=inet\s)\d+(\.\d+){3}' | grep -oP '\d+(\.\d+){3}')
    if [ ! -z "$SMF_PFCP_IP" ]; then
        echo -e "${GREEN}SMF PFCP IP: $SMF_PFCP_IP${NC}"
    else
        echo -e "${RED}SMF PFCP IP not found${NC}"
    fi
    
    # Check SMF config
    echo -e "${YELLOW}SMF ConfigMap:${NC}"
    microk8s kubectl get configmap -n $NAMESPACE v-smf-config -o yaml | grep -A10 "pfcp:"
    echo "----------------------------------------"
else
    echo -e "${RED}SMF pod not found${NC}"
fi

# Check UPF interfaces
if [ ! -z "$UPF_POD" ]; then
    echo -e "${BLUE}Checking UPF pod: $UPF_POD${NC}"
    get_pod_interfaces $UPF_POD
    
    # Get UPF PFCP IP
    UPF_PFCP_IP=$(microk8s kubectl exec -n $NAMESPACE $UPF_POD -- ip -4 -o addr show | grep -oP 'pfcp.*(?<=inet\s)\d+(\.\d+){3}' | grep -oP '\d+(\.\d+){3}')
    if [ ! -z "$UPF_PFCP_IP" ]; then
        echo -e "${GREEN}UPF PFCP IP: $UPF_PFCP_IP${NC}"
    else
        echo -e "${RED}UPF PFCP IP not found${NC}"
    fi
    
    # Get UPF GTPU IP
    UPF_GTPU_IP=$(microk8s kubectl exec -n $NAMESPACE $UPF_POD -- ip -4 -o addr show | grep -oP 'gtpu.*(?<=inet\s)\d+(\.\d+){3}' | grep -oP '\d+(\.\d+){3}')
    if [ ! -z "$UPF_GTPU_IP" ]; then
        echo -e "${GREEN}UPF GTPU IP: $UPF_GTPU_IP${NC}"
    else
        echo -e "${RED}UPF GTPU IP not found${NC}"
    fi
    
    # Check UPF config
    echo -e "${YELLOW}UPF ConfigMap:${NC}"
    microk8s kubectl get configmap -n $NAMESPACE v-upf-config -o yaml | grep -A10 "pfcp:"
    echo "----------------------------------------"
else
    echo -e "${RED}UPF pod not found${NC}"
fi

# Test PFCP connectivity between SMF and UPF
if [ ! -z "$SMF_POD" ] && [ ! -z "$UPF_POD" ] && [ ! -z "$UPF_PFCP_IP" ]; then
    echo -e "${BLUE}Testing PFCP connectivity from SMF to UPF...${NC}"
    microk8s kubectl exec -n $NAMESPACE $SMF_POD -- ping -c 3 $UPF_PFCP_IP
    
    # Check PFCP port connectivity
    echo -e "${YELLOW}Checking PFCP port connectivity...${NC}"
    microk8s kubectl exec -n $NAMESPACE $SMF_POD -- nc -zvu $UPF_PFCP_IP 8805 -w 5 || echo -e "${RED}PFCP port connectivity failed${NC}"
    
    echo "----------------------------------------"
fi

# Check AMF interfaces
if [ ! -z "$AMF_POD" ]; then
    echo -e "${BLUE}Checking AMF pod: $AMF_POD${NC}"
    get_pod_interfaces $AMF_POD
    
    # Get AMF NGAP IP
    AMF_NGAP_IP=$(microk8s kubectl exec -n $NAMESPACE $AMF_POD -- ip -4 -o addr show | grep -oP 'ngap.*(?<=inet\s)\d+(\.\d+){3}' | grep -oP '\d+(\.\d+){3}')
    if [ ! -z "$AMF_NGAP_IP" ]; then
        echo -e "${GREEN}AMF NGAP IP: $AMF_NGAP_IP${NC}"
    else
        echo -e "${RED}AMF NGAP IP not found${NC}"
    fi
    
    # Check AMF config
    echo -e "${YELLOW}AMF ConfigMap:${NC}"
    microk8s kubectl get configmap -n $NAMESPACE v-amf-config -o yaml | grep -A5 "ngap:"
    echo "----------------------------------------"
else
    echo -e "${RED}AMF pod not found${NC}"
fi

# Check PacketRusher interfaces
if [ ! -z "$PR_POD" ]; then
    echo -e "${BLUE}Checking PacketRusher pod: $PR_POD${NC}"
    get_pod_interfaces $PR_POD
    
    # Get PacketRusher NGAP IP
    PR_NGAP_IP=$(microk8s kubectl exec -n $NAMESPACE $PR_POD -- ip -4 -o addr show | grep -oP 'ngap.*(?<=inet\s)\d+(\.\d+){3}' | grep -oP '\d+(\.\d+){3}')
    if [ ! -z "$PR_NGAP_IP" ]; then
        echo -e "${GREEN}PacketRusher NGAP IP: $PR_NGAP_IP${NC}"
    else
        echo -e "${RED}PacketRusher NGAP IP not found${NC}"
    fi
    
    # Get PacketRusher GTPU IP
    PR_GTPU_IP=$(microk8s kubectl exec -n $NAMESPACE $PR_POD -- ip -4 -o addr show | grep -oP 'gtpu.*(?<=inet\s)\d+(\.\d+){3}' | grep -oP '\d+(\.\d+){3}')
    if [ ! -z "$PR_GTPU_IP" ]; then
        echo -e "${GREEN}PacketRusher GTPU IP: $PR_GTPU_IP${NC}"
    else
        echo -e "${RED}PacketRusher GTPU IP not found${NC}"
    fi
    
    # Check PacketRusher config
    echo -e "${YELLOW}PacketRusher ConfigMap:${NC}"
    microk8s kubectl get configmap -n $NAMESPACE packetrusher-config -o yaml | grep -A5 "amfif:"
    echo "----------------------------------------"
else
    echo -e "${RED}PacketRusher pod not found${NC}"
fi

# Test NGAP connectivity between AMF and PacketRusher
if [ ! -z "$AMF_POD" ] && [ ! -z "$PR_POD" ] && [ ! -z "$AMF_NGAP_IP" ] && [ ! -z "$PR_NGAP_IP" ]; then
    echo -e "${BLUE}Testing NGAP connectivity from PacketRusher to AMF...${NC}"
    microk8s kubectl exec -n $NAMESPACE $PR_POD -- ping -c 3 $AMF_NGAP_IP
    
    # Check NGAP port connectivity
    echo -e "${YELLOW}Checking NGAP port connectivity...${NC}"
    microk8s kubectl exec -n $NAMESPACE $PR_POD -- nc -zvu $AMF_NGAP_IP 38412 -w 5 || echo -e "${RED}NGAP port connectivity failed${NC}"
    
    echo "----------------------------------------"
fi

# Check logs for connection issues
echo -e "${BLUE}Checking for connection issues in logs...${NC}"

if [ ! -z "$SMF_POD" ]; then
    echo -e "${YELLOW}SMF logs related to PFCP:${NC}"
    microk8s kubectl logs -n $NAMESPACE $SMF_POD | grep -i "pfcp" | grep -i "error\|fail\|reject\|connection\|establish" | tail -10
    echo "----------------------------------------"
fi

if [ ! -z "$UPF_POD" ]; then
    echo -e "${YELLOW}UPF logs related to PFCP:${NC}"
    microk8s kubectl logs -n $NAMESPACE $UPF_POD | grep -i "pfcp" | grep -i "error\|fail\|reject\|connection\|establish" | tail -10
    echo "----------------------------------------"
fi

if [ ! -z "$AMF_POD" ]; then
    echo -e "${YELLOW}AMF logs related to NGAP:${NC}"
    microk8s kubectl logs -n $NAMESPACE $AMF_POD | grep -i "ngap" | grep -i "error\|fail\|reject\|connection\|establish" | tail -10
    echo "----------------------------------------"
fi

if [ ! -z "$PR_POD" ]; then
    echo -e "${YELLOW}PacketRusher logs related to 5GMM:${NC}"
    microk8s kubectl logs -n $NAMESPACE $PR_POD | grep -i "5gmm" | grep -i "error\|fail\|reject" | tail -10
    echo "----------------------------------------"
fi

echo -e "${GREEN}Network connectivity check completed.${NC}"
echo -e "${BLUE}These results should help you identify and resolve connectivity issues between components.${NC}"
echo -e "${YELLOW}If you still have issues, try examining individual pod logs with 'microk8s kubectl logs -n $NAMESPACE <pod-name>'${NC}"
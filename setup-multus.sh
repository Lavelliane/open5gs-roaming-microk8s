#!/bin/bash

# Script to set up Multus CNI on MicroK8s
# Created: May 2025
# Updated to fix Multus pod readiness issue

# Exit on error
set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Setting up Multus CNI for MicroK8s...${NC}"

# Check if microk8s is installed
if ! command -v microk8s &> /dev/null; then
    echo -e "${RED}Error: microk8s is not installed or not in your PATH${NC}"
    exit 1
fi

# Check if microk8s is running
if ! microk8s status | grep -q "microk8s is running"; then
    echo -e "${RED}Error: microk8s is not running. Please start it with 'microk8s start'${NC}"
    exit 1
fi

# Ensure DNS and storage are enabled
echo -e "${YELLOW}Checking required addons...${NC}"
if ! microk8s status | grep -q "dns: enabled"; then
    echo -e "${YELLOW}Enabling DNS addon...${NC}"
    microk8s enable dns
    sleep 10
fi

if ! microk8s status | grep -q "storage: enabled"; then
    echo -e "${YELLOW}Enabling storage addon...${NC}"
    microk8s enable storage
    sleep 10
fi

# Create directory for CNI config
echo -e "${YELLOW}Creating CNI configuration directory...${NC}"
CNI_DIR="/var/snap/microk8s/current/args/cni-network"
if [ ! -d "$CNI_DIR" ]; then
    sudo mkdir -p $CNI_DIR
fi

# Check if Multus is already installed
echo -e "${YELLOW}Checking if Multus is already installed...${NC}"
if microk8s kubectl get customresourcedefinition network-attachment-definitions.k8s.cni.cncf.io &>/dev/null; then
    echo -e "${GREEN}Multus CRD already exists, continuing with existing installation${NC}"
else
    # Using Helm to install Multus (more reliable)
    echo -e "${YELLOW}Installing Multus using Helm...${NC}"
    
    # Check if helm3 addon is enabled
    if ! microk8s status | grep -q "helm3: enabled"; then
        echo -e "${YELLOW}Enabling helm3 addon...${NC}"
        microk8s enable helm3
        sleep 10
    fi
    
    # Add NetworkAttachmentDefinition CRD manually first (sometimes helm chart fails to add it)
    echo -e "${YELLOW}Adding NetworkAttachmentDefinition CRD...${NC}"
    sudo wget -O /tmp/multus-crd.yaml https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus/crds/crd.yaml
    microk8s kubectl apply -f /tmp/multus-crd.yaml
    
    # Add Helm repo and install Multus
    echo -e "${YELLOW}Adding Helm repo and installing Multus...${NC}"
    microk8s helm3 repo add nfvpe https://kubevirt.github.io/helm-charts/
    microk8s helm3 repo update
    microk8s helm3 install multus nfvpe/multus --set image.tag=latest --set cni.image.tag=latest
    
    echo -e "${YELLOW}Waiting for Multus resources to be created...${NC}"
    sleep 20
fi

# Create macvlan CNI config - more reliable approach for MicroK8s
echo -e "${YELLOW}Creating macvlan CNI configuration...${NC}"
MACVLAN_CONF=$(cat <<EOF
{
  "name": "macvlan-conf",
  "cniVersion": "0.3.1",
  "plugins": [
    {
      "type": "macvlan",
      "capabilities": {"ips": true},
      "master": "eth0",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "ranges": [
          [
            {
              "subnet": "10.10.0.0/16",
              "rangeStart": "10.10.1.20",
              "rangeEnd": "10.10.1.100"
            }
          ]
        ],
        "routes": [
          { "dst": "0.0.0.0/0" }
        ]
      }
    }
  ]
}
EOF
)

echo "$MACVLAN_CONF" | sudo tee $CNI_DIR/10-macvlan.conflist > /dev/null

# Verify Multus installation
echo -e "${YELLOW}Verifying Multus installation...${NC}"
TIMEOUT=120
START_TIME=$(date +%s)

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
    
    if [ $ELAPSED_TIME -gt $TIMEOUT ]; then
        echo -e "${RED}Timeout waiting for Multus pod to be ready. Please check the logs manually:${NC}"
        echo -e "${YELLOW}microk8s kubectl get pods --all-namespaces | grep multus${NC}"
        echo -e "${YELLOW}microk8s kubectl logs -n kube-system <multus-pod-name>${NC}"
        break
    fi
    
    # Check if NetworkAttachmentDefinition CRD exists
    if microk8s kubectl get customresourcedefinition network-attachment-definitions.k8s.cni.cncf.io &>/dev/null; then
        echo -e "${GREEN}Multus CRD is installed${NC}"
        MULTUS_READY=true
        break
    else
        echo -e "${YELLOW}Waiting for Multus CRD to be created (${ELAPSED_TIME}s/${TIMEOUT}s)...${NC}"
        sleep 5
    fi
done

if [ "$MULTUS_READY" != "true" ]; then
    echo -e "${RED}Failed to install Multus CRD. Trying an alternative approach...${NC}"
    
    # Alternative approach - applying Multus directly
    echo -e "${YELLOW}Applying Multus directly...${NC}"
    sudo wget -O /tmp/multus-daemonset.yaml https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml
    
    # Apply the Multus DaemonSet
    microk8s kubectl apply -f /tmp/multus-daemonset.yaml
    
    echo -e "${YELLOW}Waiting for Multus CRD to be created...${NC}"
    TIMEOUT=120
    START_TIME=$(date +%s)
    
    while true; do
        CURRENT_TIME=$(date +%s)
        ELAPSED_TIME=$((CURRENT_TIME - START_TIME))
        
        if [ $ELAPSED_TIME -gt $TIMEOUT ]; then
            echo -e "${RED}Timeout waiting for Multus CRD. Please check the status manually.${NC}"
            break
        fi
        
        if microk8s kubectl get customresourcedefinition network-attachment-definitions.k8s.cni.cncf.io &>/dev/null; then
            echo -e "${GREEN}Multus CRD is installed${NC}"
            MULTUS_READY=true
            break
        else
            echo -e "${YELLOW}Waiting for Multus CRD to be created (${ELAPSED_TIME}s/${TIMEOUT}s)...${NC}"
            sleep 5
        fi
    done
fi

if [ "$MULTUS_READY" != "true" ]; then
    echo -e "${RED}Failed to install Multus using both methods.${NC}"
    echo -e "${RED}Please check the MicroK8s documentation or try a manual installation.${NC}"
    exit 1
fi

# Create NetworkAttachmentDefinitions in the open5gs namespace
echo -e "${YELLOW}Creating NetworkAttachmentDefinitions for 5G Core components...${NC}"

# Create namespace if it doesn't exist
microk8s kubectl create namespace open5gs --dry-run=client -o yaml | microk8s kubectl apply -f -

# Create control plane network for SBI
cat <<EOF | microk8s kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: control-plane-net
  namespace: open5gs
spec:
  config: '{
    "cniVersion": "0.3.1",
    "type": "macvlan",
    "master": "eth0",
    "mode": "bridge",
    "ipam": {
      "type": "host-local",
      "subnet": "192.168.10.0/24",
      "rangeStart": "192.168.10.100",
      "rangeEnd": "192.168.10.200",
      "gateway": "192.168.10.1"
    }
  }'
EOF

# Create PFCP network for SMF-UPF
cat <<EOF | microk8s kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: pfcp-net
  namespace: open5gs
spec:
  config: '{
    "cniVersion": "0.3.1",
    "type": "macvlan",
    "master": "eth0",
    "mode": "bridge",
    "ipam": {
      "type": "host-local",
      "subnet": "192.168.11.0/24",
      "rangeStart": "192.168.11.100",
      "rangeEnd": "192.168.11.200",
      "gateway": "192.168.11.1"
    }
  }'
EOF

# Create NGAP network for AMF-gNB
cat <<EOF | microk8s kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: ngap-net
  namespace: open5gs
spec:
  config: '{
    "cniVersion": "0.3.1",
    "type": "macvlan",
    "master": "eth0",
    "mode": "bridge",
    "ipam": {
      "type": "host-local",
      "subnet": "192.168.12.0/24",
      "rangeStart": "192.168.12.100",
      "rangeEnd": "192.168.12.200",
      "gateway": "192.168.12.1"
    }
  }'
EOF

# Create GTP-U network for UPF-gNB
cat <<EOF | microk8s kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: gtpu-net
  namespace: open5gs
spec:
  config: '{
    "cniVersion": "0.3.1",
    "type": "macvlan",
    "master": "eth0",
    "mode": "bridge",
    "ipam": {
      "type": "host-local",
      "subnet": "192.168.13.0/24",
      "rangeStart": "192.168.13.100",
      "rangeEnd": "192.168.13.200",
      "gateway": "192.168.13.1"
    }
  }'
EOF

# Verify NetworkAttachmentDefinitions were created
echo -e "${YELLOW}Verifying NetworkAttachmentDefinitions...${NC}"
microk8s kubectl get network-attachment-definitions -n open5gs

echo -e "${GREEN}Multus CNI setup completed.${NC}"
echo -e "${BLUE}You can now use Multus network interfaces in your 5G Core deployments.${NC}"
echo -e "${YELLOW}Note: If you still face issues, try restarting MicroK8s with 'microk8s stop && microk8s start'${NC}"
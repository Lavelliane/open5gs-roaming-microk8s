#!/bin/bash
# setup-multus.sh - Script to set up Multus CNI in MicroK8s

set -e

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}Setting up Multus CNI for MicroK8s...${NC}"

# Enable required MicroK8s addons
echo -e "${BLUE}Enabling required MicroK8s addons...${NC}"
microk8s enable dns storage helm3
microk8s status --wait-ready

# Create the open5gs namespace if it doesn't exist
microk8s kubectl create namespace open5gs --dry-run=client -o yaml | microk8s kubectl apply -f -

# Install Multus CNI using Helm
echo -e "${BLUE}Installing Multus CNI using Helm...${NC}"
microk8s helm3 repo add k8s-at-home https://k8s-at-home.com/charts/
microk8s helm3 repo update
microk8s helm3 install multus k8s-at-home/multus --namespace kube-system

# Wait for Multus to be ready
echo -e "${BLUE}Waiting for Multus DaemonSet to be ready...${NC}"
microk8s kubectl rollout status daemonset/multus -n kube-system --timeout=120s

# Create NetworkAttachmentDefinitions
echo -e "${BLUE}Creating NetworkAttachmentDefinitions for 5G components...${NC}"

# PFCP Network for SMF-UPF communication
cat <<EOF | microk8s kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: pfcp-network
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
      "rangeEnd": "192.168.10.200"
    }
  }'
EOF

# GTP-U Network for user plane traffic
cat <<EOF | microk8s kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: gtpu-network
  namespace: open5gs
spec:
  config: '{
    "cniVersion": "0.3.1",
    "type": "macvlan",
    "master": "eth0",
    "mode": "bridge",
    "ipam": {
      "type": "host-local",
      "subnet": "192.168.20.0/24",
      "rangeStart": "192.168.20.100",
      "rangeEnd": "192.168.20.200"
    }
  }'
EOF

# NGAP Network for AMF-gNodeB communication
cat <<EOF | microk8s kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: ngap-network
  namespace: open5gs
spec:
  config: '{
    "cniVersion": "0.3.1",
    "type": "macvlan",
    "master": "eth0",
    "mode": "bridge",
    "ipam": {
      "type": "host-local",
      "subnet": "192.168.30.0/24",
      "rangeStart": "192.168.30.100",
      "rangeEnd": "192.168.30.200"
    }
  }'
EOF

echo -e "${GREEN}Multus CNI setup complete!${NC}"
echo -e "${YELLOW}Note: You may need to adjust the network interface 'master' value if your MicroK8s host uses a different interface name than 'eth0'${NC}"
echo -e "${BLUE}You can check the status of Multus with: microk8s kubectl get pods -n kube-system | grep multus${NC}"
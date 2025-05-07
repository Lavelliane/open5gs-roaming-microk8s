#!/bin/bash

# Script to set up Multus CNI on MicroK8s
# Created: May 2025

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
fi

if ! microk8s status | grep -q "storage: enabled"; then
    echo -e "${YELLOW}Enabling storage addon...${NC}"
    microk8s enable storage
fi

# Create a directory for CNI config
echo -e "${YELLOW}Creating CNI configuration directory...${NC}"
CNI_DIR="/var/snap/microk8s/current/args/cni-network"
sudo mkdir -p $CNI_DIR

# Download and install Multus CNI
echo -e "${YELLOW}Downloading Multus CNI...${NC}"
MULTUS_VERSION="v4.0.2"
sudo wget -O /tmp/multus.yml https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/$MULTUS_VERSION/deployments/multus-daemonset.yml

# Update multus ConfigMap to work with MicroK8s
echo -e "${YELLOW}Customizing Multus configuration for MicroK8s...${NC}"
sed -i 's|/etc/cni/net.d|/var/snap/microk8s/current/args/cni-network|g' /tmp/multus.yml
sed -i 's|/opt/cni/bin|/var/snap/microk8s/current/opt/cni/bin|g' /tmp/multus.yml

# Apply Multus DaemonSet
echo -e "${YELLOW}Applying Multus DaemonSet...${NC}"
microk8s kubectl apply -f /tmp/multus.yml

# Wait for Multus DaemonSet to be ready
echo -e "${YELLOW}Waiting for Multus DaemonSet to be ready...${NC}"
while [[ $(microk8s kubectl get pods -n kube-system -l name=multus -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do
    echo -e "${YELLOW}Waiting for Multus pod to be ready...${NC}"
    sleep 5
done

# Create macvlan CNI config
echo -e "${YELLOW}Creating macvlan CNI configuration...${NC}"
cat <<EOF | sudo tee $CNI_DIR/00-multus.conf
{
  "name": "multus-cni-network",
  "type": "multus",
  "kubeconfig": "/var/snap/microk8s/current/credentials/client.config",
  "delegates": [
    {
      "type": "calico",
      "name": "calico-k8s-network",
      "cniVersion": "0.3.1",
      "datastore_type": "kubernetes",
      "nodename": "__KUBERNETES_NODE_NAME__",
      "ipam": {
        "type": "host-local",
        "subnet": "10.1.0.0/16"
      }
    }
  ]
}
EOF

# Restart microk8s to apply changes
echo -e "${YELLOW}Restarting MicroK8s to apply changes...${NC}"
microk8s stop
sleep 5
microk8s start
sleep 10

# Wait for microk8s to be ready
echo -e "${YELLOW}Waiting for MicroK8s to be ready...${NC}"
microk8s status --wait-ready

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

echo -e "${GREEN}Multus CNI setup completed successfully!${NC}"
echo -e "${BLUE}You can now use Multus network interfaces in your 5G Core deployments.${NC}"
echo -e "${YELLOW}Note: You may need to modify your interface settings based on your specific network configuration.${NC}"
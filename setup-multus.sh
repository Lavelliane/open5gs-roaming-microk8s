#!/bin/bash

# Setup Multus CNI for MicroK8s
# This script installs and configures Multus CNI for use with MicroK8s

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}Checking MicroK8s status...${NC}"
if ! microk8s status | grep -q "running"; then
  echo -e "${RED}MicroK8s is not running. Please start MicroK8s first.${NC}"
  exit 1
fi

echo -e "${BLUE}Enabling required MicroK8s addons...${NC}"
microk8s enable dns storage helm3

echo -e "${BLUE}Installing Multus CNI...${NC}"
microk8s kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml

echo -e "${YELLOW}Waiting for Multus to be ready...${NC}"
sleep 10

# Check if Multus is installed
echo -e "${BLUE}Verifying Multus installation...${NC}"
PODS=$(microk8s kubectl get pods -n kube-system -l name=multus)
if echo "$PODS" | grep -q "Running"; then
  echo -e "${GREEN}Multus CNI installed successfully!${NC}"
else
  echo -e "${RED}Multus CNI installation failed. Please check the logs.${NC}"
  echo -e "${YELLOW}You can check the logs with: microk8s kubectl logs -n kube-system -l name=multus${NC}"
  exit 1
fi

# Create default macvlan network-attachment-definition
echo -e "${BLUE}Creating default macvlan network attachment definition...${NC}"
cat <<EOF | microk8s kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: macvlan-conf
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "10.45.0.0/16",
        "rangeStart": "10.45.1.1",
        "rangeEnd": "10.45.254.254",
        "gateway": "10.45.0.1"
      }
    }'
EOF

echo -e "${GREEN}Setup completed!${NC}"
echo -e "${BLUE}You can now use Multus CNI in your 5G core deployment.${NC}"
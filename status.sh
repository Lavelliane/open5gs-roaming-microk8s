#!/bin/bash
# check-status.sh

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

NAMESPACE="open5gs"

echo -e "${BLUE}Pod Status:${NC}"
microk8s kubectl get pods -n $NAMESPACE

echo -e "\n${BLUE}StatefulSets:${NC}"
microk8s kubectl get statefulsets -n $NAMESPACE

echo -e "\n${BLUE}PersistentVolumeClaims:${NC}"
microk8s kubectl get pvc -n $NAMESPACE

echo -e "\n${BLUE}Services:${NC}"
microk8s kubectl get services -n $NAMESPACE

echo -e "\n${BLUE}Network Attachment Definitions:${NC}"
microk8s kubectl get network-attachment-definitions

echo -e "\n${BLUE}Storage Classes:${NC}"
microk8s kubectl get sc

echo -e "\n${BLUE}Checking MongoDB:${NC}"
MONGODB_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=mongodb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$MONGODB_POD" ]; then
  echo -e "${GREEN}MongoDB pod: $MONGODB_POD${NC}"
  echo -e "${YELLOW}MongoDB logs:${NC}"
  microk8s kubectl logs -n $NAMESPACE $MONGODB_POD --tail=20
else
  echo -e "${RED}MongoDB pod not found${NC}"
  echo -e "${YELLOW}StatefulSet events:${NC}"
  microk8s kubectl describe statefulset mongodb -n $NAMESPACE
fi

echo -e "\n${BLUE}Checking Multus:${NC}"
microk8s kubectl get pods -n kube-system -l app=multus
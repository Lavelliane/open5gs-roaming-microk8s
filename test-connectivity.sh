#!/bin/bash

# test-connectivity.sh
# This script tests network connectivity between 5G core components

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default namespace
NAMESPACE="open5gs"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--namespace namespace]"
      exit 1
      ;;
  esac
done

echo -e "${BLUE}Testing UPF network interfaces...${NC}"
UPF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-upf -o jsonpath='{.items[0].metadata.name}')
if [ -n "$UPF_POD" ]; then
  echo -e "${YELLOW}IP addresses on UPF pod:${NC}"
  microk8s kubectl exec -n $NAMESPACE $UPF_POD -- ip addr | grep -E "inet |inet6 " | grep -v "127.0.0.1" | grep -v "::1"

  echo -e "${YELLOW}Testing connectivity from UPF to SMF:${NC}"
  microk8s kubectl exec -n $NAMESPACE $UPF_POD -- ping -c 3 v-smf-n4
else
  echo -e "${RED}UPF pod not found${NC}"
fi

echo -e "\n${BLUE}Testing SMF network interfaces...${NC}"
SMF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-smf -o jsonpath='{.items[0].metadata.name}')
if [ -n "$SMF_POD" ]; then
  echo -e "${YELLOW}IP addresses on SMF pod:${NC}"
  microk8s kubectl exec -n $NAMESPACE $SMF_POD -- ip addr | grep -E "inet |inet6 " | grep -v "127.0.0.1" | grep -v "::1"

  echo -e "${YELLOW}Testing connectivity from SMF to UPF:${NC}"
  microk8s kubectl exec -n $NAMESPACE $SMF_POD -- ping -c 3 v-upf-n4
else
  echo -e "${RED}SMF pod not found${NC}"
fi

echo -e "\n${BLUE}Testing AMF network interfaces...${NC}"
AMF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-amf -o jsonpath='{.items[0].metadata.name}')
if [ -n "$AMF_POD" ]; then
  echo -e "${YELLOW}IP addresses on AMF pod:${NC}"
  microk8s kubectl exec -n $NAMESPACE $AMF_POD -- ip addr | grep -E "inet |inet6 " | grep -v "127.0.0.1" | grep -v "::1"

  echo -e "${YELLOW}Testing connectivity from AMF to PacketRusher:${NC}"
  microk8s kubectl exec -n $NAMESPACE $AMF_POD -- ping -c 3 packetrusher
else
  echo -e "${RED}AMF pod not found${NC}"
fi

echo -e "\n${BLUE}Testing PacketRusher network interfaces...${NC}"
PR_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=packetrusher -o jsonpath='{.items[0].metadata.name}')
if [ -n "$PR_POD" ]; then
  echo -e "${YELLOW}IP addresses on PacketRusher pod:${NC}"
  microk8s kubectl exec -n $NAMESPACE $PR_POD -- ip addr | grep -E "inet |inet6 " | grep -v "127.0.0.1" | grep -v "::1"

  echo -e "${YELLOW}Testing connectivity from PacketRusher to AMF:${NC}"
  microk8s kubectl exec -n $NAMESPACE $PR_POD -- ping -c 3 v-amf-n2
else
  echo -e "${RED}PacketRusher pod not found${NC}"
fi

echo -e "\n${BLUE}Checking UPF logs for tun interface setup:${NC}"
if [ -n "$UPF_POD" ]; then
  microk8s kubectl logs -n $NAMESPACE $UPF_POD | grep -E "TUN|PFCP|GTP"
else
  echo -e "${RED}UPF pod not found${NC}"
fi

echo -e "\n${BLUE}Checking SMF logs for connection to UPF:${NC}"
if [ -n "$SMF_POD" ]; then
  microk8s kubectl logs -n $NAMESPACE $SMF_POD | grep -E "PFCP|UPF|Association"
else
  echo -e "${RED}SMF pod not found${NC}"
fi

echo -e "\n${BLUE}Checking AMF logs for gNB and UE connections:${NC}"
if [ -n "$AMF_POD" ]; then
  microk8s kubectl logs -n $NAMESPACE $AMF_POD | grep -E "gNB|UE|NGAP|registration"
else
  echo -e "${RED}AMF pod not found${NC}"
fi

echo -e "\n${GREEN}Testing complete!${NC}"
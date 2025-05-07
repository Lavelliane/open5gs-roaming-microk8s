#!/bin/bash

# Script to update network configurations for Open5GS in MicroK8s
# This script updates ConfigMaps and restarts components to apply new network settings

set -e

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
    --namespace|-n)
      NAMESPACE="$2"
      shift 2
      ;;
    --force|-f)
      FORCE=true
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--namespace|-n NAMESPACE] [--force|-f]"
      echo "  --namespace, -n: Specify the namespace (default: open5gs)"
      echo "  --force, -f: Skip confirmation prompt"
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

# Check for namespace existence
if ! microk8s kubectl get namespace $NAMESPACE &> /dev/null; then
  echo -e "${RED}Error: Namespace $NAMESPACE does not exist${NC}"
  exit 1
fi

# Display warning unless force mode is enabled
if [ "$FORCE" != "true" ]; then
  echo -e "${RED}WARNING: This will update ConfigMaps and restart all pods in namespace $NAMESPACE${NC}"
  echo -e "${YELLOW}Make sure you have backed up any custom configurations${NC}"
  echo ""
  read -p "Are you sure you want to continue? (y/N): " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}Operation cancelled${NC}"
    exit 0
  fi
fi

echo -e "${BLUE}Starting network configuration update for namespace $NAMESPACE...${NC}"

# Function to update ConfigMap
update_configmap() {
  local name=$1
  local file_path=$2
  local config_data=$3
  
  echo -e "${YELLOW}Updating ConfigMap $name...${NC}"
  
  # Check if ConfigMap exists
  if microk8s kubectl get configmap $name -n $NAMESPACE &> /dev/null; then
    # Create a temporary file with the new config data
    echo "$config_data" > /tmp/$name-config.yaml
    
    # Update the ConfigMap
    microk8s kubectl create configmap $name -n $NAMESPACE --from-file=$file_path=/tmp/$name-config.yaml --dry-run=client -o yaml | microk8s kubectl apply -f -
    
    echo -e "${GREEN}ConfigMap $name updated${NC}"
  else
    echo -e "${RED}ConfigMap $name does not exist${NC}"
  fi
}

# Function to restart deployment
restart_deployment() {
  local name=$1
  
  echo -e "${YELLOW}Restarting deployment $name...${NC}"
  
  # Check if deployment exists
  if microk8s kubectl get deployment $name -n $NAMESPACE &> /dev/null; then
    # Restart the deployment by patching it with a restart annotation
    TIMESTAMP=$(date +%s)
    microk8s kubectl patch deployment $name -n $NAMESPACE -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"kubectl.kubernetes.io/restartedAt\":\"$(date -d @$TIMESTAMP -Iseconds)\"}}}}}"
    
    # Wait for the deployment to restart
    microk8s kubectl rollout status deployment $name -n $NAMESPACE --timeout=60s
    
    echo -e "${GREEN}Deployment $name restarted${NC}"
  else
    echo -e "${RED}Deployment $name does not exist${NC}"
  fi
}

# Update SMF ConfigMap with new PFCP and GTP-U network settings
echo -e "${BLUE}Updating SMF configuration...${NC}"
update_configmap "v-smf-config" "smf.yaml" "logger:
  file:
    path: /var/log/open5gs/smf.log
  level: trace

global:

smf:
  sbi:
    server:
      - address: 0.0.0.0
        port: 80
    client:
      nrf:
        - uri: http://v-nrf.open5gs.svc.cluster.local:80
  pfcp:
    server:
      - address: 192.168.10.102
        port: 8805
    client:
      upf:
        - address: 192.168.10.101
          port: 8805
  gtpu:
    server:
      - address: 192.168.20.102
  session:
    - subnet: 10.45.0.0/16
      gateway: 10.45.0.1
  dns:
    - 8.8.8.8
    - 8.8.4.4
  mtu: 1400"

# Update UPF ConfigMap with new PFCP and GTP-U network settings
echo -e "${BLUE}Updating UPF configuration...${NC}"
update_configmap "v-upf-config" "upf.yaml" "logger:
  file:
    path: /var/log/open5gs/upf.log
  level: trace

global:

upf:
  pfcp:
    server:
      - address: 192.168.10.101
        port: 8805
  gtpu:
    server:
      - address: 192.168.20.101
  session:
    - subnet: 10.45.0.0/16
      gateway: 10.45.0.1"

# Update AMF ConfigMap with new NGAP network settings
echo -e "${BLUE}Updating AMF configuration...${NC}"
update_configmap "v-amf-config" "amf.yaml" "logger:
  file:
    path: /var/log/open5gs/amf.log
  level: trace

global:

amf:
  sbi:
    server:
      - address: 0.0.0.0
        port: 80
    client:
      nrf:
        - uri: http://v-nrf.open5gs.svc.cluster.local:80
  ngap:
    server:
      - address: 192.168.30.101
  access_control:
    - plmn_id:
        mcc: 999
        mnc: 70
    - plmn_id:
        mcc: 001
        mnc: 01
  guami:
    - plmn_id:
        mcc: 999
        mnc: 70
      amf_id:
        region: 2
        set: 1
  tai:
    - plmn_id:
        mcc: 999
        mnc: 70
      tac: 1
    - plmn_id:
        mcc: 001
        mnc: 01
      tac: 1
  plmn_support:
    - plmn_id:
        mcc: 999
        mnc: 70
      s_nssai:
        - sst: 1
          sd: 000001
    - plmn_id:
        mcc: 001
        mnc: 01
      s_nssai:
        - sst: 1
          sd: 000001
  security:
    integrity_order: [ NIA2, NIA0, NIA1 ]
    ciphering_order: [ NEA0, NEA2, NEA1 ]
  network_name:
    full: Open5GS
  amf_name: open5gs-amf0
  time:
    t3512:
      value: 540"

# Update PacketRusher ConfigMap
echo -e "${BLUE}Updating PacketRusher configuration...${NC}"
update_configmap "packetrusher-config" "config.yml" "gnodeb:
  controlif:
    ip: '192.168.30.102'
    port: 38412
  dataif:
    ip: '192.168.20.103'
    port: 2152
  plmnlist:
    mcc: '999'
    mnc: '70'
    tac: '000001'
    gnbid: '000008'
  slicesupportlist:
    sst: '01'
    sd: '000001'

ue:
  hplmn:
    mcc: '001'
    mnc: '01'
  msin: '1234567891'
  key: '7F176C500D47CF2090CB6D91F4A73479'
  opc: '3D45770E83C7BBB6900F3653FDA6330F'
  dnn: 'internet'
  snssai:
    sst: 01
    sd: '000001'
  amf: '8000'
  sqn: '00000000'
  protectionScheme: 0
  integrity:
    nia0: false
    nia1: false
    nia2: true
    nia3: false
  ciphering:
    nea0: true
    nea1: false
    nea2: true
    nea3: false

amfif:
  - ip: '192.168.30.101'
    port: 38412

logs:
  level: 4"

# Patch SMF deployment with Multus annotation
echo -e "${BLUE}Updating SMF deployment with Multus annotation...${NC}"
microk8s kubectl patch deployment v-smf -n $NAMESPACE --type=json -p='[
  {
    "op": "add", 
    "path": "/spec/template/metadata/annotations", 
    "value": {
      "k8s.v1.cni.cncf.io/networks": "[{\"name\":\"pfcp-network\",\"interface\":\"pfcp\",\"ips\":[\"192.168.10.102/24\"]},{\"name\":\"gtpu-network\",\"interface\":\"gtpu\",\"ips\":[\"192.168.20.102/24\"]}]"
    }
  }
]'

# Patch UPF deployment with Multus annotation
echo -e "${BLUE}Updating UPF deployment with Multus annotation...${NC}"
microk8s kubectl patch deployment v-upf -n $NAMESPACE --type=json -p='[
  {
    "op": "add", 
    "path": "/spec/template/metadata/annotations", 
    "value": {
      "k8s.v1.cni.cncf.io/networks": "[{\"name\":\"pfcp-network\",\"interface\":\"pfcp\",\"ips\":[\"192.168.10.101/24\"]},{\"name\":\"gtpu-network\",\"interface\":\"gtpu\",\"ips\":[\"192.168.20.101/24\"]}]"
    }
  }
]'

# Patch AMF deployment with Multus annotation
echo -e "${BLUE}Updating AMF deployment with Multus annotation...${NC}"
microk8s kubectl patch deployment v-amf -n $NAMESPACE --type=json -p='[
  {
    "op": "add", 
    "path": "/spec/template/metadata/annotations", 
    "value": {
      "k8s.v1.cni.cncf.io/networks": "[{\"name\":\"ngap-network\",\"interface\":\"ngap\",\"ips\":[\"192.168.30.101/24\"]}]"
    }
  }
]'

# Patch PacketRusher deployment with Multus annotation
echo -e "${BLUE}Updating PacketRusher deployment with Multus annotation...${NC}"
microk8s kubectl patch deployment packetrusher -n $NAMESPACE --type=json -p='[
  {
    "op": "add", 
    "path": "/spec/template/metadata/annotations", 
    "value": {
      "k8s.v1.cni.cncf.io/networks": "[{\"name\":\"ngap-network\",\"interface\":\"ngap\",\"ips\":[\"192.168.30.102/24\"]},{\"name\":\"gtpu-network\",\"interface\":\"gtpu\",\"ips\":[\"192.168.20.103/24\"]}]"
    }
  }
]'

# Wait for all deployments to be ready
echo -e "${BLUE}Waiting for all pods to be ready...${NC}"
microk8s kubectl wait --for=condition=ready pods --all -n $NAMESPACE --timeout=180s

# Verify the updates were applied
echo -e "${BLUE}Verifying network configurations...${NC}"

# Check UPF pod interface configuration
UPF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-upf -o jsonpath='{.items[0].metadata.name}')
if [ -n "$UPF_POD" ]; then
  echo -e "${YELLOW}UPF pod network interfaces:${NC}"
  microk8s kubectl exec -n $NAMESPACE $UPF_POD -- ip addr | grep -E "pfcp|gtpu"
fi

# Check SMF pod interface configuration
SMF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-smf -o jsonpath='{.items[0].metadata.name}')
if [ -n "$SMF_POD" ]; then
  echo -e "${YELLOW}SMF pod network interfaces:${NC}"
  microk8s kubectl exec -n $NAMESPACE $SMF_POD -- ip addr | grep -E "pfcp|gtpu"
fi

# Check AMF pod interface configuration
AMF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-amf -o jsonpath='{.items[0].metadata.name}')
if [ -n "$AMF_POD" ]; then
  echo -e "${YELLOW}AMF pod network interfaces:${NC}"
  microk8s kubectl exec -n $NAMESPACE $AMF_POD -- ip addr | grep -E "ngap"
fi

# Check PacketRusher pod interface configuration
PR_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=packetrusher -o jsonpath='{.items[0].metadata.name}')
if [ -n "$PR_POD" ]; then
  echo -e "${YELLOW}PacketRusher pod network interfaces:${NC}"
  microk8s kubectl exec -n $NAMESPACE $PR_POD -- ip addr | grep -E "ngap|gtpu"
fi

echo -e "${GREEN}Network configuration update completed!${NC}"
echo -e "${BLUE}You can now run the debug-network.sh script to verify that everything is working properly${NC}"
#!/bin/bash

# 5G Core Network Deployment Script with Multus CNI
# This script deploys the components of a 5G core network using Kustomize and Multus CNI
# Exit on error
set -e

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default subscriber values
NAMESPACE="open5gs"
IMSI="001011234567891"
KEY="7F176C500D47CF2090CB6D91F4A73479"
OPC="3D45770E83C7BBB6900F3653FDA6330F"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --imsi)
      IMSI="$2"
      shift 2
      ;;
    --key)
      KEY="$2"
      shift 2
      ;;
    --opc)
      OPC="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--namespace namespace] [--imsi IMSI] [--key KEY] [--opc OPC]"
      exit 1
      ;;
  esac
done

# Create namespace if it doesn't exist
echo -e "${BLUE}Creating namespace $NAMESPACE if it doesn't exist...${NC}"
microk8s kubectl create namespace $NAMESPACE --dry-run=client -o yaml | microk8s kubectl apply -f -
echo -e "${GREEN}Namespace ready${NC}"
echo "----------------------------------------"

# Check prerequisites
echo -e "${BLUE}Checking if required addons are enabled in microk8s...${NC}"
if ! microk8s status | grep -q "storage: enabled"; then
  echo -e "${YELLOW}Storage not enabled. Enabling now...${NC}"
  microk8s enable storage
  sleep 10  # Give it time to initialize
fi

if ! microk8s kubectl get customresourcedefinition network-attachment-definitions.k8s.cni.cncf.io &>/dev/null; then
  echo -e "${RED}Multus CNI not detected. Please run setup-multus.sh first.${NC}"
  exit 1
fi
echo -e "${GREEN}Prerequisites ready${NC}"
echo "----------------------------------------"

# Create network attachment definitions if they don't exist
echo -e "${BLUE}Checking network attachment definitions...${NC}"
if ! microk8s kubectl get networkattachmentdefinition -n $NAMESPACE control-plane-net &>/dev/null; then
  echo -e "${YELLOW}Control plane network not found. Creating network attachment definitions...${NC}"
  
  # Control plane network
  cat <<EOF | microk8s kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: control-plane-net
  namespace: $NAMESPACE
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

  # PFCP network
  cat <<EOF | microk8s kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: pfcp-net
  namespace: $NAMESPACE
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

  # NGAP network
  cat <<EOF | microk8s kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: ngap-net
  namespace: $NAMESPACE
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

  # GTP-U network
  cat <<EOF | microk8s kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: gtpu-net
  namespace: $NAMESPACE
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
  echo -e "${GREEN}Network attachment definitions created${NC}"
else
  echo -e "${GREEN}Network attachment definitions already exist${NC}"
fi
echo "----------------------------------------"

# Create services for accessing Multus interfaces
echo -e "${BLUE}Creating services for Multus interfaces...${NC}"

# UPF PFCP Service
cat <<EOF | microk8s kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: v-upf-pfcp
  namespace: $NAMESPACE
spec:
  selector:
    app: v-upf
  ports:
    - name: pfcp
      protocol: UDP
      port: 8805
      targetPort: 8805
EOF

# SMF PFCP Service
cat <<EOF | microk8s kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: v-smf-pfcp
  namespace: $NAMESPACE
spec:
  selector:
    app: v-smf
  ports:
    - name: pfcp
      protocol: UDP
      port: 8805
      targetPort: 8805
EOF

# AMF NGAP Service
cat <<EOF | microk8s kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: v-amf-ngap
  namespace: $NAMESPACE
spec:
  selector:
    app: v-amf
  ports:
    - name: ngap
      protocol: SCTP
      port: 38412
      targetPort: 38412
EOF

echo -e "${GREEN}Multus interface services created${NC}"
echo "----------------------------------------"

# Step 1: Deploy MongoDB using StatefulSet (Shared data store)
echo -e "${BLUE}Deploying MongoDB StatefulSet...${NC}"

# Apply MongoDB StatefulSet from kustomize base
echo -e "Applying MongoDB from kustomize base..."
microk8s kubectl apply -k kustomize/base/mongodb -n $NAMESPACE

# Wait for MongoDB to be ready
echo -e "${BLUE}Waiting for MongoDB pod to be ready...${NC}"
microk8s kubectl wait --for=condition=ready pods -l app=mongodb -n $NAMESPACE --timeout=180s

# Add after MongoDB pod is ready, before adding subscriber
echo -e "${BLUE}Waiting for MongoDB to fully initialize...${NC}"
sleep 15  # Give MongoDB time to start accepting connections

# Find MongoDB pod
echo -e "${BLUE}Finding MongoDB pod...${NC}"
MONGODB_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=mongodb -o jsonpath='{.items[0].metadata.name}')

if [ -z "$MONGODB_POD" ]; then
  echo -e "${RED}Error: MongoDB pod not found${NC}"
  exit 1
fi

echo -e "${GREEN}Found MongoDB pod: $MONGODB_POD${NC}"

# Step 2: Add subscriber to MongoDB
echo -e "${BLUE}Adding subscriber with IMSI $IMSI to MongoDB...${NC}"

# Create MongoDB script with fixed syntax
cat > /tmp/add-subscriber.js << EOF
db = db.getSiblingDB('open5gs');

// Check if subscribers collection exists
if (!db.getCollectionNames().includes('subscribers')) {
    db.createCollection('subscribers');
    print("Created subscribers collection");
}

// Add subscriber with IMSI $IMSI
db.subscribers.updateOne(
    { imsi: "$IMSI" },
    {
        \$setOnInsert: {
            "schema_version": NumberInt(1),
            "imsi": "$IMSI",
            "msisdn": [],
            "imeisv": "1110000000000000",
            "mme_host": [],
            "mm_realm": [],
            "purge_flag": [],
            "slice":[
            {
                "sst": NumberInt(1),
                "sd": "000001",
                "default_indicator": true,
                "session": [
                {
                    "name" : "internet",
                    "type" : NumberInt(3),
                    "qos" :
                    { "index": NumberInt(9),
                        "arp":
                        {
                            "priority_level" : NumberInt(8),
                            "pre_emption_capability": NumberInt(1),
                            "pre_emption_vulnerability": NumberInt(1)
                        }
                    },
                    "ambr":
                    {
                        "downlink":
                        {
                            "value": NumberInt(1),
                            "unit": NumberInt(3)
                        },
                        "uplink":
                        {
                            "value": NumberInt(1),
                            "unit": NumberInt(3)
                        }
                    },
                    "pcc_rule": [],
                    "_id": new ObjectId(),
                }],
                "_id": new ObjectId(),
            }],
            "security":
            {
                "k" : "$KEY",
                "op" : null,
                "opc" : "$OPC",
                "amf" : "8000",
                "sqn" : NumberLong(1184)
            },
            "ambr" :
            {
                "downlink" : { "value": NumberInt(1), "unit": NumberInt(3)},
                "uplink" : { "value": NumberInt(1), "unit": NumberInt(3)}
            },
            "access_restriction_data": 32,
            "network_access_mode": 2,
            "subscriber_status": 0,
            "operator_determined_barring": 0,
            "subscribed_rau_tau_timer": 12,
            "__v": 0
        }
    },
    { upsert: true }
);

// Verify subscriber was added
var subscriber = db.subscribers.findOne({imsi: "$IMSI"});
if (subscriber) {
    print("Subscriber " + "$IMSI" + " added or updated successfully");
} else {
    print("ERROR: Failed to add subscriber " + "$IMSI");
}

// Count total subscribers
var count = db.subscribers.count();
print("Total subscribers in database: " + count);
EOF

# Copy script to pod
echo -e "Copying script to MongoDB pod..."
microk8s kubectl cp /tmp/add-subscriber.js $NAMESPACE/$MONGODB_POD:/tmp/add-subscriber.js

# Execute script in pod
echo -e "Executing script in MongoDB pod..."
microk8s kubectl exec -n $NAMESPACE $MONGODB_POD -- mongo --quiet /tmp/add-subscriber.js

# Create verification script with fixed syntax
cat > /tmp/verify-subscriber.js << EOF
db = db.getSiblingDB('open5gs');
var subscriber = db.subscribers.findOne({imsi: "$IMSI"});
if (subscriber) {
    print("SUCCESS: Subscriber " + "$IMSI" + " exists in database");
    printjson(subscriber);
} else {
    print("ERROR: Subscriber " + "$IMSI" + " not found in database");
}
EOF

# Copy and execute verification script
echo -e "Verifying subscriber was added..."
microk8s kubectl cp /tmp/verify-subscriber.js $NAMESPACE/$MONGODB_POD:/tmp/verify-subscriber.js
microk8s kubectl exec -n $NAMESPACE $MONGODB_POD -- mongo --quiet /tmp/verify-subscriber.js

echo -e "${GREEN}Subscriber addition completed${NC}"
echo "----------------------------------------"

# Apply Kustomize overlay with Multus
echo -e "${YELLOW}Deploying 5G Core components with Multus using Kustomize...${NC}"
microk8s kubectl apply -k kustomize/overlays/multus -n $NAMESPACE

# Wait for pods to be ready
echo -e "${BLUE}Waiting for all pods to be ready...${NC}"
microk8s kubectl wait --for=condition=ready pods --all --namespace=$NAMESPACE --timeout=300s

# Get pod IPs for Multus interfaces
echo -e "${BLUE}Getting pod IPs for Multus interfaces...${NC}"

# Get SMF pod name
SMF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-smf -o jsonpath='{.items[0].metadata.name}')
echo -e "SMF Pod: $SMF_POD"

# Get SMF pod IPs
SMF_PFCP_IP=$(microk8s kubectl exec -n $NAMESPACE $SMF_POD -- ip -4 -o addr show pfcp | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo -e "SMF PFCP IP: $SMF_PFCP_IP"

# Update SMF ConfigMap
if [ ! -z "$SMF_PFCP_IP" ]; then
  echo -e "Updating SMF configuration with PFCP IP..."
  microk8s kubectl get cm -n $NAMESPACE v-smf-config -o yaml | sed "s/\$(POD_IP_PFCP)/$SMF_PFCP_IP/g" | microk8s kubectl apply -f -
  
  # Restart SMF pod to apply changes
  echo -e "Restarting SMF pod to apply changes..."
  microk8s kubectl delete pod -n $NAMESPACE $SMF_POD
fi

# Get UPF pod name
UPF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-upf -o jsonpath='{.items[0].metadata.name}')
echo -e "UPF Pod: $UPF_POD"

# Wait for UPF pod to be ready
echo -e "Waiting for UPF pod to be ready..."
microk8s kubectl wait --for=condition=ready pod -n $NAMESPACE $UPF_POD --timeout=180s

# Get UPF pod IPs
UPF_PFCP_IP=$(microk8s kubectl exec -n $NAMESPACE $UPF_POD -- ip -4 -o addr show pfcp | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
UPF_GTPU_IP=$(microk8s kubectl exec -n $NAMESPACE $UPF_POD -- ip -4 -o addr show gtpu | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo -e "UPF PFCP IP: $UPF_PFCP_IP"
echo -e "UPF GTPU IP: $UPF_GTPU_IP"

# Update UPF ConfigMap
if [ ! -z "$UPF_PFCP_IP" ] && [ ! -z "$UPF_GTPU_IP" ]; then
  echo -e "Updating UPF configuration with PFCP and GTPU IPs..."
  microk8s kubectl get cm -n $NAMESPACE v-upf-config -o yaml | sed "s/\$(POD_IP_PFCP)/$UPF_PFCP_IP/g" | sed "s/\$(POD_IP_GTPU)/$UPF_GTPU_IP/g" | microk8s kubectl apply -f -
  
  # Restart UPF pod to apply changes
  echo -e "Restarting UPF pod to apply changes..."
  microk8s kubectl delete pod -n $NAMESPACE $UPF_POD
fi

# Wait for restarted pods to be ready
echo -e "${BLUE}Waiting for restarted pods to be ready...${NC}"
microk8s kubectl wait --for=condition=ready pods --all --namespace=$NAMESPACE --timeout=300s

# Get AMF pod name
AMF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-amf -o jsonpath='{.items[0].metadata.name}')
echo -e "AMF Pod: $AMF_POD"

# Get PacketRusher pod name
PR_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=packetrusher -o jsonpath='{.items[0].metadata.name}')
echo -e "PacketRusher Pod: $PR_POD"

# Update PacketRusher ConfigMap with AMF NGAP IP
AMF_NGAP_IP=$(microk8s kubectl exec -n $NAMESPACE $AMF_POD -- ip -4 -o addr show ngap | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo -e "AMF NGAP IP: $AMF_NGAP_IP"

if [ ! -z "$AMF_NGAP_IP" ]; then
  echo -e "Updating PacketRusher configuration with AMF NGAP IP..."
  microk8s kubectl get cm -n $NAMESPACE packetrusher-config -o yaml | sed "s/v-amf.open5gs.svc.cluster.local/$AMF_NGAP_IP/g" | microk8s kubectl apply -f -
  
  # Restart PacketRusher pod to apply changes
  echo -e "Restarting PacketRusher pod to apply changes..."
  microk8s kubectl delete pod -n $NAMESPACE $PR_POD
fi

# Wait for final deployments to be ready
echo -e "${BLUE}Waiting for all pods to be in Running state...${NC}"
microk8s kubectl wait --for=condition=ready pods --all --namespace=$NAMESPACE --timeout=300s

# Show status of all resources
echo -e "${BLUE}Showing status of all resources in the $NAMESPACE namespace:${NC}"
echo "----------------------------------------"
echo "Pods:"
microk8s kubectl get pods -n $NAMESPACE
echo "----------------------------------------"
echo "Services:"
microk8s kubectl get services -n $NAMESPACE
echo "----------------------------------------"
echo "Network Attachment Definitions:"
microk8s kubectl get networkattachmentdefinition -n $NAMESPACE
echo "----------------------------------------"

# Add at the end before final message
echo -e "${BLUE}Testing network connectivity between components...${NC}"

# Test PFCP connectivity between SMF and UPF
echo -e "Testing PFCP connectivity between SMF and UPF..."
SMF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-smf -o jsonpath='{.items[0].metadata.name}')
UPF_PFCP_IP=$(microk8s kubectl exec -n $NAMESPACE $UPF_POD -- ip -4 -o addr show pfcp | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

if [ ! -z "$UPF_PFCP_IP" ]; then
  microk8s kubectl exec -n $NAMESPACE $SMF_POD -- ping -c 2 $UPF_PFCP_IP || echo "PFCP connectivity issues detected"
else
  echo -e "${RED}UPF PFCP IP not found${NC}"
fi

# Test NGAP connectivity between AMF and PacketRusher
echo -e "Testing NGAP connectivity between AMF and PacketRusher..."
AMF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-amf -o jsonpath='{.items[0].metadata.name}')
PR_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=packetrusher -o jsonpath='{.items[0].metadata.name}')
PR_NGAP_IP=$(microk8s kubectl exec -n $NAMESPACE $PR_POD -- ip -4 -o addr show ngap | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
AMF_NGAP_IP=$(microk8s kubectl exec -n $NAMESPACE $AMF_POD -- ip -4 -o addr show ngap | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

if [ ! -z "$PR_NGAP_IP" ] && [ ! -z "$AMF_NGAP_IP" ]; then
  echo -e "PacketRusher NGAP IP: $PR_NGAP_IP"
  echo -e "AMF NGAP IP: $AMF_NGAP_IP"
  microk8s kubectl exec -n $NAMESPACE $PR_POD -- ping -c 2 $AMF_NGAP_IP || echo "NGAP connectivity issues detected"
else
  echo -e "${RED}PacketRusher or AMF NGAP IP not found${NC}"
fi

echo -e "${GREEN}Deployment complete with subscriber IMSI: $IMSI added to MongoDB${NC}"
echo -e "${BLUE}5G Core Network with Multus CNI has been deployed${NC}"
echo -e "${YELLOW}Check the logs of each component for detailed status${NC}"
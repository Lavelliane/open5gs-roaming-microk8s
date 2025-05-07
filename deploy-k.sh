#!/bin/bash

# deploy-kustomize.sh
# This script deploys the 5G core network using Kustomize

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default namespace
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

# Verify Kustomize directory exists
if [ ! -d "kustomize" ]; then
  echo -e "${RED}Error: kustomize directory not found. Please run this script from the repository root.${NC}"
  exit 1
fi

# Check if Multus is installed
echo -e "${BLUE}Checking Multus CNI installation...${NC}"
if ! microk8s kubectl get daemonset -n kube-system | grep -q "kube-multus"; then
  echo -e "${YELLOW}Multus CNI not detected. Installing...${NC}"
  ./setup-multus.sh
else
  echo -e "${GREEN}Multus CNI is installed.${NC}"
fi

# Create namespace if it doesn't exist
echo -e "${BLUE}Creating namespace $NAMESPACE if it doesn't exist...${NC}"
microk8s kubectl create namespace $NAMESPACE --dry-run=client -o yaml | microk8s kubectl apply -f -
echo -e "${GREEN}Namespace ready${NC}"

# Deploy using Kustomize
echo -e "${BLUE}Deploying 5G Core Network using Kustomize...${NC}"
microk8s kubectl apply -k kustomize/overlays/microk8s

# Wait for MongoDB to be ready
echo -e "${BLUE}Waiting for MongoDB pod to be ready...${NC}"
microk8s kubectl wait --for=condition=ready pods -l app=mongodb -n $NAMESPACE --timeout=180s

# Add subscriber to MongoDB
echo -e "${BLUE}Adding subscriber with IMSI $IMSI to MongoDB...${NC}"

# Find MongoDB pod
MONGODB_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=mongodb -o jsonpath='{.items[0].metadata.name}')

if [ -z "$MONGODB_POD" ]; then
  echo -e "${RED}Error: MongoDB pod not found${NC}"
  exit 1
fi

echo -e "${GREEN}Found MongoDB pod: $MONGODB_POD${NC}"

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

# Wait for all pods to be ready
echo -e "${BLUE}Waiting for all pods to be ready...${NC}"
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
echo "Network-Attachment-Definitions:"
microk8s kubectl get network-attachment-definitions
echo "----------------------------------------"

# Add instructions to test the deployment
echo -e "${GREEN}Deployment complete!${NC}"
echo -e "${BLUE}To verify the deployment:${NC}"
echo -e "1. Check UPF interface configuration:"
echo -e "   microk8s kubectl exec -n $NAMESPACE \$(microk8s kubectl get pods -n $NAMESPACE -l app=v-upf -o jsonpath='{.items[0].metadata.name}') -- ip addr"
echo -e "2. Check SMF interface configuration:"
echo -e "   microk8s kubectl exec -n $NAMESPACE \$(microk8s kubectl get pods -n $NAMESPACE -l app=v-smf -o jsonpath='{.items[0].metadata.name}') -- ip addr"
echo -e "3. Check AMF logs for UE registration:"
echo -e "   microk8s kubectl logs -n $NAMESPACE \$(microk8s kubectl get pods -n $NAMESPACE -l app=v-amf -o jsonpath='{.items[0].metadata.name}')"
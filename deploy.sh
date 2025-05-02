#!/bin/bash

# Ordered 5G Core Network Deployment Script
# This script deploys the components of a 5G core network in the proper hierarchical order
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

# Add this near the beginning, after namespace creation
echo -e "${BLUE}Checking if storage is enabled in microk8s...${NC}"
if ! microk8s status | grep -q "storage: enabled"; then
  echo -e "${YELLOW}Storage not enabled. Enabling now...${NC}"
  microk8s enable storage
  sleep 10  # Give it time to initialize
fi
echo -e "${GREEN}Storage ready${NC}"

# Step 1: Deploy MongoDB using StatefulSet (Shared data store)
echo -e "${BLUE}Deploying MongoDB StatefulSet...${NC}"

# Create MongoDB StatefulSet YAML
cat > /tmp/mongodb-statefulset.yaml << EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: $NAMESPACE
spec:
  serviceName: mongodb
  replicas: 1
  selector:
    matchLabels:
      app: mongodb
  template:
    metadata:
      labels:
        app: mongodb
    spec:
      containers:
        - name: mongodb
          image: mongo:4.4
          command: ["mongod", "--bind_ip", "0.0.0.0", "--port", "27017"]
          ports:
            - containerPort: 27017
          volumeMounts:
            - name: db-data
              mountPath: /data/db
            - name: db-config
              mountPath: /data/configdb
  volumeClaimTemplates:
    - metadata:
        name: db-data
      spec:
        accessModes: [ "ReadWriteOnce" ]
        resources:
          requests:
            storage: 1Gi
    - metadata:
        name: db-config
      spec:
        accessModes: [ "ReadWriteOnce" ]
        resources:
          requests:
            storage: 500Mi
EOF

# Apply MongoDB StatefulSet
echo -e "Applying MongoDB StatefulSet..."
microk8s kubectl apply -f /tmp/mongodb-statefulset.yaml -n $NAMESPACE

# Check if service.yaml exists in shared/mongodb directory
if [ -f "shared/mongodb/service.yaml" ]; then
    echo -e "Applying MongoDB service..."
    microk8s kubectl apply -f shared/mongodb/service.yaml -n $NAMESPACE
else
    # Create MongoDB service YAML if doesn't exist
    cat > /tmp/mongodb-service.yaml << EOF
apiVersion: v1
kind: Service
metadata:
  name: mongodb
  namespace: $NAMESPACE
spec:
  selector:
    app: mongodb
  ports:
  - port: 27017
    targetPort: 27017
  clusterIP: None
EOF
    echo -e "Applying MongoDB service..."
    microk8s kubectl apply -f /tmp/mongodb-service.yaml -n $NAMESPACE
fi

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

# Function to deploy components from a directory
deploy_components() {
    local dir=$1
    local component_name=$(basename "$dir")
    local prefix=$2
    
    echo -e "${BLUE}Deploying $prefix $component_name...${NC}"
    
    # Change to the directory
    cd "$dir"
    
    # Apply configmap if it exists
    if [ -f "configmap.yaml" ]; then
        echo -e "Applying configmap for $prefix $component_name..."
        microk8s kubectl apply -f configmap.yaml -n $NAMESPACE
    fi
    
    # Apply deployment
    if [ -f "deployment.yaml" ]; then
        echo -e "Applying deployment for $prefix $component_name..."
        microk8s kubectl apply -f deployment.yaml -n $NAMESPACE
    else
        echo -e "${RED}Warning: No deployment.yaml found for $prefix $component_name${NC}"
    fi
    
    # Apply service
    if [ -f "service.yaml" ]; then
        echo -e "Applying service for $prefix $component_name..."
        microk8s kubectl apply -f service.yaml -n $NAMESPACE
    else
        echo -e "${RED}Warning: No service.yaml found for $prefix $component_name${NC}"
    fi
    
    echo -e "${GREEN}Finished deploying $prefix $component_name${NC}"
    echo "----------------------------------------"
    
    # Return to original directory
    cd - > /dev/null
}

# Step 3: Deploy Network Functions in logical order

# Deploy NRF first (Network Repository Function - the service registry)
echo -e "${YELLOW}[1/4] Deploying NRF components (Service Registry)...${NC}"
deploy_components "home/nrf" "Home"
deploy_components "visiting/nrf" "Visiting"
echo -e "${GREEN}NRF components deployed successfully${NC}"

# Deploy UDR/UDM/AUSF (User data management and authentication)
echo -e "${YELLOW}[2/4] Deploying Subscriber Data Management components...${NC}"
deploy_components "home/udr" "Home"
deploy_components "home/udm" "Home"
deploy_components "home/ausf" "Home"
deploy_components "visiting/ausf" "Visiting"
echo -e "${GREEN}Subscriber Data Management components deployed successfully${NC}"


# Deploy Core Network Functions
echo -e "${YELLOW}[3/4] Deploying Core Network Functions...${NC}"
deploy_components "visiting/nssf" "Visiting"
deploy_components "visiting/bsf" "Visiting"
deploy_components "visiting/pcf" "Visiting"
deploy_components "home/sepp" "Home"
deploy_components "visiting/sepp" "Visiting"
echo -e "${GREEN}Core Network Functions deployed successfully${NC}"

# Add after both SEPPs are deployed
echo -e "${BLUE}Verifying SEPP certificate volumes...${NC}"
microk8s kubectl get pvc -n $NAMESPACE | grep -E "h-sepp-certs|v-sepp-certs"
if [ $? -ne 0 ]; then
  echo -e "${YELLOW}Warning: SEPP certificate volumes may not be properly provisioned${NC}"
fi

# Deploy User Plane and Mobility Functions (SMF, UPF, AMF)
echo -e "${YELLOW}[4/4] Deploying User Plane and Mobility Management components...${NC}"
deploy_components "visiting/smf" "Visiting"
deploy_components "visiting/upf" "Visiting"
deploy_components "visiting/amf" "Visiting"
echo -e "${GREEN}User Plane and Mobility Management components deployed successfully${NC}"

# Deploy PacketRusher (simulated User Equipment)
echo -e "${YELLOW}Deploying PacketRusher (UE simulator)...${NC}"
deploy_components "shared/packetrusher" "Shared"
echo -e "${GREEN}PacketRusher deployed successfully${NC}"

# Add after all components are deployed
echo -e "${BLUE}Giving PacketRusher extra time to initialize...${NC}"
sleep 20

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
echo "Deployments:"
microk8s kubectl get deployments -n $NAMESPACE
echo "----------------------------------------"

# Add at the end before final message
echo -e "${BLUE}Testing network connectivity between components...${NC}"
AMF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-amf -o jsonpath='{.items[0].metadata.name}')
microk8s kubectl exec -n $NAMESPACE $AMF_POD -- ping -c 2 v-nrf.open5gs.svc.cluster.local || echo "Connectivity issues detected"

echo -e "${GREEN}Deployment complete with subscriber IMSI: $IMSI added to MongoDB${NC}"
echo -e "${BLUE}To add more subscribers, use the add-k8s-subscriber.sh script${NC}"
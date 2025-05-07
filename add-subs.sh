#!/bin/bash
# add-subscriber.sh

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
NAMESPACE="open5gs"
IMSI="001011234567891"
KEY="7F176C500D47CF2090CB6D91F4A73479" 
OPC="3D45770E83C7BBB6900F3653FDA6330F"

# Find MongoDB pod
echo -e "${BLUE}Finding MongoDB pod...${NC}"
MONGODB_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=mongodb -o jsonpath='{.items[0].metadata.name}')

if [ -z "$MONGODB_POD" ]; then
  echo -e "${RED}Error: MongoDB pod not found${NC}"
  echo -e "${YELLOW}Checking all pods in namespace:${NC}"
  microk8s kubectl get pods -n $NAMESPACE
  exit 1
fi

echo -e "${GREEN}Found MongoDB pod: $MONGODB_POD${NC}"

# Create MongoDB script
echo -e "${BLUE}Creating subscriber script...${NC}"
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
EOF

# Copy script to pod
echo -e "${BLUE}Copying script to MongoDB pod...${NC}"
microk8s kubectl cp /tmp/add-subscriber.js $NAMESPACE/$MONGODB_POD:/tmp/add-subscriber.js

# Execute script in pod
echo -e "${BLUE}Executing script in MongoDB pod...${NC}"
microk8s kubectl exec -n $NAMESPACE $MONGODB_POD -- mongo --quiet /tmp/add-subscriber.js

echo -e "${GREEN}Subscriber added successfully!${NC}"
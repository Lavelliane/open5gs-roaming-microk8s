#!/bin/bash
# deploy-mongodb.sh

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default namespace
NAMESPACE="open5gs"

# Create namespace if it doesn't exist
echo -e "${BLUE}Creating namespace $NAMESPACE if it doesn't exist...${NC}"
microk8s kubectl create namespace $NAMESPACE --dry-run=client -o yaml | microk8s kubectl apply -f -

# Deploy MongoDB
echo -e "${BLUE}Deploying MongoDB...${NC}"
cat <<EOF | microk8s kubectl apply -f -
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
---
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
  volumeClaimTemplates:
    - metadata:
        name: db-data
      spec:
        accessModes: [ "ReadWriteOnce" ]
        resources:
          requests:
            storage: 1Gi
EOF

# Wait for MongoDB to start
echo -e "${BLUE}Waiting for MongoDB pod to start...${NC}"
sleep 15

# Check if MongoDB pod exists
MONGODB_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=mongodb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$MONGODB_POD" ]; then
  echo -e "${RED}MongoDB pod not found. Checking for issues...${NC}"
  microk8s kubectl get statefulset -n $NAMESPACE
  microk8s kubectl describe statefulset mongodb -n $NAMESPACE
  microk8s kubectl get pvc -n $NAMESPACE
  echo -e "${RED}Please fix storage issues if any and try again.${NC}"
  exit 1
fi

echo -e "${GREEN}MongoDB pod found: $MONGODB_POD${NC}"
echo -e "${BLUE}Waiting for MongoDB pod to be ready...${NC}"
timeout 60s microk8s kubectl wait --for=condition=ready pod $MONGODB_POD -n $NAMESPACE

echo -e "${GREEN}MongoDB deployed successfully!${NC}"
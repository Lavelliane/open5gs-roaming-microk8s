#!/bin/bash

# migrate-to-kustomize.sh
# Migrates the existing configurations to a Kustomize structure

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}Creating Kustomize directory structure...${NC}"
mkdir -p kustomize/base
mkdir -p kustomize/overlays/microk8s
mkdir -p kustomize/base/common
mkdir -p kustomize/base/home-components
mkdir -p kustomize/base/visiting-components
mkdir -p kustomize/base/network-definitions

echo -e "${BLUE}Copying MongoDB configuration...${NC}"
cp shared/mongodb/service.yaml kustomize/base/common/mongodb-service.yaml
cp shared/mongodb/statefulset.yaml kustomize/base/common/mongodb-statefulset.yaml

echo -e "${BLUE}Creating MongoDB kustomization file...${NC}"
cat > kustomize/base/common/mongodb.yaml << EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
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
---
apiVersion: v1
kind: Service
metadata:
  name: mongodb
spec:
  selector:
    app: mongodb
  ports:
  - port: 27017
    targetPort: 27017
  clusterIP: None
EOF

echo -e "${BLUE}Copying PacketRusher configuration...${NC}"
cp shared/packetrusher/configmap.yaml kustomize/base/common/packetrusher-configmap.yaml
cp shared/packetrusher/deployment.yaml kustomize/base/common/packetrusher-deployment.yaml
cp shared/packetrusher/service.yaml kustomize/base/common/packetrusher-service.yaml

echo -e "${BLUE}Copying Home components...${NC}"
for component in nrf ausf udm udr sepp; do
  mkdir -p kustomize/base/home-components/$component
  cp home/$component/configmap.yaml kustomize/base/home-components/$component/configmap.yaml
  cp home/$component/deployment.yaml kustomize/base/home-components/$component/deployment.yaml
  cp home/$component/service.yaml kustomize/base/home-components/$component/service.yaml
  
  # Create a combined file
  cat > kustomize/base/home-components/$component.yaml << EOF
$(cat home/$component/configmap.yaml)
---
$(cat home/$component/deployment.yaml)
---
$(cat home/$component/service.yaml)
EOF
done

echo -e "${BLUE}Copying Visiting components...${NC}"
for component in nrf ausf nssf bsf pcf sepp smf upf amf; do
  mkdir -p kustomize/base/visiting-components/$component
  cp visiting/$component/configmap.yaml kustomize/base/visiting-components/$component/configmap.yaml
  cp visiting/$component/deployment.yaml kustomize/base/visiting-components/$component/deployment.yaml
  cp visiting/$component/service.yaml kustomize/base/visiting-components/$component/service.yaml
  
  # Create a combined file
  cat > kustomize/base/visiting-components/$component.yaml << EOF
$(cat visiting/$component/configmap.yaml)
---
$(cat visiting/$component/deployment.yaml)
---
$(cat visiting/$component/service.yaml)
EOF
done

echo -e "${BLUE}Creating network definitions...${NC}"
cat > kustomize/base/network-definitions/5g-networks.yaml << EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: 5g-n2-net
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "10.100.100.0/24",
        "rangeStart": "10.100.100.100",
        "rangeEnd": "10.100.100.200"
      }
    }'
---
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: 5g-n3-net
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "10.100.200.0/24",
        "rangeStart": "10.100.200.100",
        "rangeEnd": "10.100.200.200"
      }
    }'
---
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: 5g-n4-net
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "10.100.50.0/24",
        "rangeStart": "10.100.50.100",
        "rangeEnd": "10.100.50.200"
      }
    }'
---
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: 5g-n6-net
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

echo -e "${BLUE}Creating base kustomization.yaml...${NC}"
cat > kustomize/base/kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - network-definitions/5g-networks.yaml
  - common/mongodb.yaml
  - home-components/nrf.yaml
  - home-components/udr.yaml
  - home-components/udm.yaml
  - home-components/ausf.yaml
  - home-components/sepp.yaml
  - visiting-components/nrf.yaml
  - visiting-components/ausf.yaml
  - visiting-components/nssf.yaml
  - visiting-components/bsf.yaml
  - visiting-components/pcf.yaml
  - visiting-components/sepp.yaml
  - visiting-components/smf.yaml
  - visiting-components/upf.yaml
  - visiting-components/amf.yaml
  - common/packetrusher.yaml

namespace: open5gs
EOF

echo -e "${BLUE}Creating MicroK8s overlay...${NC}"
mkdir -p kustomize/overlays/microk8s/patches

cat > kustomize/overlays/microk8s/kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

namespace: open5gs

patchesStrategicMerge:
  - patches/network-adjustments.yaml
EOF

cat > kustomize/overlays/microk8s/patches/network-adjustments.yaml << EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: 5g-n4-net
spec:
  config: '{
      "cniVersion": "0.3.1",
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "10.100.50.0/24",
        "rangeStart": "10.100.50.100",
        "rangeEnd": "10.100.50.200"
      }
    }'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: v-upf
spec:
  template:
    spec:
      hostNetwork: true
EOF

echo -e "${GREEN}Migration to Kustomize structure complete!${NC}"
echo -e "${BLUE}You can now deploy the 5G core using:${NC}"
echo -e "./deploy-k.sh"
#!/bin/bash

# Script to set up Kustomize structure for 5G Core deployment
# Created: May 2025

# Exit on error
set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Setting up Kustomize structure for 5G Core deployment...${NC}"

# Create base directory structure
echo -e "${YELLOW}Creating directory structure...${NC}"
mkdir -p kustomize/base/{mongodb,packetrusher,home,visiting}
mkdir -p kustomize/base/home/{nrf,udr,udm,ausf,sepp}
mkdir -p kustomize/base/visiting/{nrf,ausf,nssf,bsf,pcf,sepp,smf,upf,amf}
mkdir -p kustomize/overlays/{default,multus}

# Create the base kustomization.yaml
cat <<EOF > kustomize/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - mongodb
  - home/nrf
  - home/udr
  - home/udm
  - home/ausf
  - home/sepp
  - visiting/nrf
  - visiting/ausf
  - visiting/nssf
  - visiting/bsf
  - visiting/pcf
  - visiting/sepp
  - visiting/smf
  - visiting/upf
  - visiting/amf
  - packetrusher

namespace: open5gs
EOF

# Create MongoDB base
echo -e "${YELLOW}Creating MongoDB base resources...${NC}"
cp shared/mongodb/service.yaml kustomize/base/mongodb/service.yaml
cp shared/mongodb/statefulset.yaml kustomize/base/mongodb/statefulset.yaml

cat <<EOF > kustomize/base/mongodb/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - service.yaml
  - statefulset.yaml
EOF

# Function to copy component files to kustomize structure
copy_component_files() {
    local component_path=$1
    local kustomize_path=$2
    
    if [ -f "$component_path/configmap.yaml" ]; then
        cp "$component_path/configmap.yaml" "$kustomize_path/configmap.yaml"
    fi
    
    if [ -f "$component_path/deployment.yaml" ]; then
        cp "$component_path/deployment.yaml" "$kustomize_path/deployment.yaml"
    fi
    
    if [ -f "$component_path/service.yaml" ]; then
        cp "$component_path/service.yaml" "$kustomize_path/service.yaml"
    fi
    
    # Create kustomization.yaml for the component
    cat <<EOF > "$kustomize_path/kustomization.yaml"
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
EOF
    
    if [ -f "$component_path/configmap.yaml" ]; then
        echo "  - configmap.yaml" >> "$kustomize_path/kustomization.yaml"
    fi
    
    if [ -f "$component_path/deployment.yaml" ]; then
        echo "  - deployment.yaml" >> "$kustomize_path/kustomization.yaml"
    fi
    
    if [ -f "$component_path/service.yaml" ]; then
        echo "  - service.yaml" >> "$kustomize_path/kustomization.yaml"
    fi
}

# Copy home components
echo -e "${YELLOW}Copying home components...${NC}"
copy_component_files "home/nrf" "kustomize/base/home/nrf"
copy_component_files "home/udr" "kustomize/base/home/udr"
copy_component_files "home/udm" "kustomize/base/home/udm"
copy_component_files "home/ausf" "kustomize/base/home/ausf"
copy_component_files "home/sepp" "kustomize/base/home/sepp"

# Copy visiting components
echo -e "${YELLOW}Copying visiting components...${NC}"
copy_component_files "visiting/nrf" "kustomize/base/visiting/nrf"
copy_component_files "visiting/ausf" "kustomize/base/visiting/ausf"
copy_component_files "visiting/nssf" "kustomize/base/visiting/nssf"
copy_component_files "visiting/bsf" "kustomize/base/visiting/bsf"
copy_component_files "visiting/pcf" "kustomize/base/visiting/pcf"
copy_component_files "visiting/sepp" "kustomize/base/visiting/sepp"
copy_component_files "visiting/smf" "kustomize/base/visiting/smf"
copy_component_files "visiting/upf" "kustomize/base/visiting/upf"
copy_component_files "visiting/amf" "kustomize/base/visiting/amf"

# Copy PacketRusher
echo -e "${YELLOW}Copying PacketRusher component...${NC}"
copy_component_files "shared/packetrusher" "kustomize/base/packetrusher"

# Create default overlay
echo -e "${YELLOW}Creating default overlay...${NC}"
cat <<EOF > kustomize/overlays/default/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

# Add common labels to all resources
commonLabels:
  app.kubernetes.io/part-of: open5gs
  app.kubernetes.io/managed-by: kustomize
EOF

# Create multus overlay
echo -e "${YELLOW}Creating multus overlay with network patches...${NC}"

mkdir -p kustomize/overlays/multus/{visiting/smf,visiting/upf,visiting/amf,packetrusher}

# SMF patch for Multus
cat <<EOF > kustomize/overlays/multus/visiting/smf/deployment-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: v-smf
spec:
  template:
    metadata:
      annotations:
        k8s.v1.cni.cncf.io/networks: '[
          {"name": "control-plane-net", "interface": "sbi"},
          {"name": "pfcp-net", "interface": "pfcp"}
        ]'
    spec:
      containers:
        - name: v-smf
          env:
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
EOF

# UPF patch for Multus
cat <<EOF > kustomize/overlays/multus/visiting/upf/deployment-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: v-upf
spec:
  template:
    metadata:
      annotations:
        k8s.v1.cni.cncf.io/networks: '[
          {"name": "pfcp-net", "interface": "pfcp"},
          {"name": "gtpu-net", "interface": "gtpu"}
        ]'
    spec:
      containers:
        - name: v-upf
          env:
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
EOF

# AMF patch for Multus
cat <<EOF > kustomize/overlays/multus/visiting/amf/deployment-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: v-amf
spec:
  template:
    metadata:
      annotations:
        k8s.v1.cni.cncf.io/networks: '[
          {"name": "control-plane-net", "interface": "sbi"},
          {"name": "ngap-net", "interface": "ngap"}
        ]'
    spec:
      containers:
        - name: v-amf
          env:
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
EOF

# PacketRusher patch for Multus
cat <<EOF > kustomize/overlays/multus/packetrusher/deployment-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: packetrusher
spec:
  template:
    metadata:
      annotations:
        k8s.v1.cni.cncf.io/networks: '[
          {"name": "ngap-net", "interface": "ngap"},
          {"name": "gtpu-net", "interface": "gtpu"}
        ]'
    spec:
      containers:
        - name: packetrusher
          env:
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
EOF

# Create kustomization.yaml for multus overlay
cat <<EOF > kustomize/overlays/multus/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base

# Add common labels to all resources
commonLabels:
  app.kubernetes.io/part-of: open5gs
  app.kubernetes.io/managed-by: kustomize
  network.open5gs.io/multus-enabled: "true"

patchesStrategicMerge:
  - visiting/smf/deployment-patch.yaml
  - visiting/upf/deployment-patch.yaml
  - visiting/amf/deployment-patch.yaml
  - packetrusher/deployment-patch.yaml
EOF

echo -e "${GREEN}Kustomize structure setup completed successfully!${NC}"
echo -e "${BLUE}You can now use kustomize to deploy your 5G Core network with:${NC}"
echo -e "${YELLOW}microk8s kubectl apply -k kustomize/overlays/default${NC}"
echo -e "${YELLOW}OR${NC}"
echo -e "${YELLOW}microk8s kubectl apply -k kustomize/overlays/multus${NC}"
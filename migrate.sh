#!/bin/bash

# Step 3: Migrate existing YAML files to Kustomize structure with Multus
# This script creates a Kustomize directory structure and migrates existing
# YAML files with necessary modifications for Multus CNI networking

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
    --help|-h)
      echo "Usage: $0 [--namespace|-n NAMESPACE]"
      echo "  --namespace, -n: Specify the namespace (default: open5gs)"
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

echo -e "${BLUE}=== Step 3: Migrating YAML files to Kustomize structure with Multus ===${NC}"

# Create Kustomize directory structure
echo -e "${BLUE}Creating Kustomize directory structure...${NC}"
mkdir -p kustomize/base/{mongodb,home,visiting,shared} kustomize/overlays/default

# Create base kustomization.yaml
cat > kustomize/base/kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - mongodb
  - home
  - visiting
  - shared
EOF

# Create home components kustomization
mkdir -p kustomize/base/home/{nrf,udr,udm,ausf,sepp}
cat > kustomize/base/home/kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - nrf
  - udr
  - udm
  - ausf
  - sepp
EOF

# Create visiting components kustomization
mkdir -p kustomize/base/visiting/{nrf,ausf,nssf,bsf,pcf,sepp,smf,upf,amf}
cat > kustomize/base/visiting/kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - nrf
  - ausf
  - nssf
  - bsf
  - pcf
  - sepp
  - smf
  - upf
  - amf
EOF

# Create shared components kustomization
mkdir -p kustomize/base/shared/packetrusher
cat > kustomize/base/shared/kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - packetrusher
EOF

# Create overlay kustomization
cat > kustomize/overlays/default/kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: $NAMESPACE

bases:
  - ../../base
EOF

# Function to migrate regular components
migrate_component() {
  local src_dir=$1
  local dest_dir=$2
  
  # Skip if source directory doesn't exist
  if [ ! -d "$src_dir" ]; then
    echo -e "${YELLOW}Source directory $src_dir does not exist, skipping${NC}"
    return
  fi
  
  echo -e "${BLUE}Migrating files from $src_dir to $dest_dir${NC}"
  
  # Create kustomization.yaml in the destination directory
  cat > "$dest_dir/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml

configMapGenerator:
  - name: $(basename "$src_dir")-config
    files:
      - $(basename "$src_dir").yaml
EOF
  
  # Copy and migrate ConfigMap
  if [ -f "$src_dir/configmap.yaml" ]; then
    # Extract the configuration from configmap.yaml
    CONFIG_FILE=$(basename "$src_dir").yaml
    grep -A 1000 "data:" "$src_dir/configmap.yaml" | grep -v "data:" | sed '1d' > "$dest_dir/$CONFIG_FILE"
    echo -e "${GREEN}Created $dest_dir/$CONFIG_FILE${NC}"
  fi
  
  # Copy and migrate Deployment
  if [ -f "$src_dir/deployment.yaml" ]; then
    cp "$src_dir/deployment.yaml" "$dest_dir/deployment.yaml"
    echo -e "${GREEN}Copied deployment.yaml${NC}"
  fi
  
  # Copy and migrate Service
  if [ -f "$src_dir/service.yaml" ]; then
    cp "$src_dir/service.yaml" "$dest_dir/service.yaml"
    echo -e "${GREEN}Copied service.yaml${NC}"
  fi
}

# Function to migrate with Multus annotations
migrate_component_with_multus() {
  local src_dir=$1
  local dest_dir=$2
  local component=$3
  local multus_annotations=$4
  
  # First perform regular migration
  migrate_component "$src_dir" "$dest_dir"
  
  # If deployment exists, add Multus annotations
  if [ -f "$dest_dir/deployment.yaml" ]; then
    echo -e "${BLUE}Adding Multus annotations to $dest_dir/deployment.yaml${NC}"
    
    # Create a temporary file
    TEMP_FILE=$(mktemp)
    
    # Add annotations to the pod template
    AWK_SCRIPT=$(cat << 'EOF'
BEGIN { in_metadata = 0; annotation_added = 0; }
/metadata:/ && !in_metadata { in_metadata = 1; next; }
/^ {4}labels:/ && in_metadata {
  print $0;
  print "      annotations:";
  print "        k8s.v1.cni.cncf.io/networks: |";
  print "          MULTUS_ANNOTATION";
  annotation_added = 1;
  next;
}
{ print $0; }
EOF
)
    
    awk -v multus="$multus_annotations" '{ gsub("MULTUS_ANNOTATION", multus); print }' <<< "$AWK_SCRIPT" > "$TEMP_FILE"
    
    # Use the script to modify the deployment file
    awk -f "$TEMP_FILE" "$dest_dir/deployment.yaml" > "$dest_dir/deployment.yaml.new"
    mv "$dest_dir/deployment.yaml.new" "$dest_dir/deployment.yaml"
    
    # Clean up
    rm "$TEMP_FILE"
    
    echo -e "${GREEN}Added Multus annotations to $dest_dir/deployment.yaml${NC}"
  fi
}

# Migrate MongoDB
echo -e "${BLUE}Migrating MongoDB...${NC}"
mkdir -p kustomize/base/mongodb
if [ -f "shared/mongodb/service.yaml" ]; then
  cp shared/mongodb/service.yaml kustomize/base/mongodb/
  echo -e "${GREEN}Copied MongoDB service.yaml${NC}"
fi
if [ -f "shared/mongodb/statefulset.yaml" ]; then
  cp shared/mongodb/statefulset.yaml kustomize/base/mongodb/
  echo -e "${GREEN}Copied MongoDB statefulset.yaml${NC}"
fi

# Create MongoDB kustomization.yaml
cat > kustomize/base/mongodb/kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - service.yaml
  - statefulset.yaml
EOF

# Migrate Home components
for component in nrf udr udm ausf sepp; do
  migrate_component "home/$component" "kustomize/base/home/$component"
done

# Migrate Visiting components (without Multus first)
for component in nrf ausf nssf bsf pcf sepp; do
  migrate_component "visiting/$component" "kustomize/base/visiting/$component"
done

# Migrate SMF with Multus annotations
SMF_MULTUS='[
  {
    "name": "pfcp-network",
    "interface": "pfcp",
    "ips": ["192.168.10.102/24"]
  },
  {
    "name": "gtpu-network",
    "interface": "gtpu",
    "ips": ["192.168.20.102/24"]
  }
]'
migrate_component_with_multus "visiting/smf" "kustomize/base/visiting/smf" "v-smf" "$SMF_MULTUS"

# Modify SMF config file with Multus interface IPs
if [ -f "kustomize/base/visiting/smf/smf.yaml" ]; then
  sed -i 's/address: 0.0.0.0/address: 192.168.10.102/g' "kustomize/base/visiting/smf/smf.yaml"
  sed -i 's/upf:\n            - address: v-upf.open5gs.svc.cluster.local/upf:\n            - address: 192.168.10.101/g' "kustomize/base/visiting/smf/smf.yaml"
  sed -i 's/server:\n          - address: 0.0.0.0/server:\n          - address: 192.168.20.102/g' "kustomize/base/visiting/smf/smf.yaml"
  echo -e "${GREEN}Updated SMF config with Multus IPs${NC}"
fi

# Migrate UPF with Multus annotations
UPF_MULTUS='[
  {
    "name": "pfcp-network",
    "interface": "pfcp",
    "ips": ["192.168.10.101/24"]
  },
  {
    "name": "gtpu-network",
    "interface": "gtpu",
    "ips": ["192.168.20.101/24"]
  }
]'
migrate_component_with_multus "visiting/upf" "kustomize/base/visiting/upf" "v-upf" "$UPF_MULTUS"

# Modify UPF config file with Multus interface IPs
if [ -f "kustomize/base/visiting/upf/upf.yaml" ]; then
  sed -i 's/address: 0.0.0.0/address: 192.168.10.101/g' "kustomize/base/visiting/upf/upf.yaml"
  sed -i 's/server:\n          - address: 0.0.0.0/server:\n          - address: 192.168.20.101/g' "kustomize/base/visiting/upf/upf.yaml"
  echo -e "${GREEN}Updated UPF config with Multus IPs${NC}"
fi

# Migrate AMF with Multus annotations
AMF_MULTUS='[
  {
    "name": "ngap-network",
    "interface": "ngap",
    "ips": ["192.168.30.101/24"]
  }
]'
migrate_component_with_multus "visiting/amf" "kustomize/base/visiting/amf" "v-amf" "$AMF_MULTUS"

# Modify AMF config file with Multus interface IPs
if [ -f "kustomize/base/visiting/amf/amf.yaml" ]; then
  sed -i 's/server:\n          - address: 0.0.0.0/server:\n          - address: 192.168.30.101/g' "kustomize/base/visiting/amf/amf.yaml"
  echo -e "${GREEN}Updated AMF config with Multus IPs${NC}"
fi

# Migrate PacketRusher
mkdir -p kustomize/base/shared/packetrusher
if [ -f "shared/packetrusher/configmap.yaml" ]; then
  # Extract config from ConfigMap
  grep -A 1000 "data:" "shared/packetrusher/configmap.yaml" | grep -v "data:" | sed '1d' > "kustomize/base/shared/packetrusher/config.yml"
  echo -e "${GREEN}Created PacketRusher config.yml${NC}"
  
  # Update PacketRusher config with Multus IPs
  sed -i 's/ip: .0.0.0.0./ip: .192.168.30.102./g' "kustomize/base/shared/packetrusher/config.yml"
  sed -i 's/ip: .v-amf.open5gs.svc.cluster.local./ip: .192.168.30.101./g' "kustomize/base/shared/packetrusher/config.yml"
  echo -e "${GREEN}Updated PacketRusher config with Multus IPs${NC}"
fi

if [ -f "shared/packetrusher/deployment.yaml" ]; then
  cp "shared/packetrusher/deployment.yaml" "kustomize/base/shared/packetrusher/deployment.yaml"
  echo -e "${GREEN}Copied PacketRusher deployment.yaml${NC}"
  
  # Add Multus annotations to PacketRusher
  PR_MULTUS='[
  {
    "name": "ngap-network",
    "interface": "ngap",
    "ips": ["192.168.30.102/24"]
  },
  {
    "name": "gtpu-network",
    "interface": "gtpu",
    "ips": ["192.168.20.103/24"]
  }
]'
  
  # Create a temporary file
  TEMP_FILE=$(mktemp)
  
  # Add annotations to the pod template
  AWK_SCRIPT=$(cat << 'EOF'
BEGIN { in_metadata = 0; annotation_added = 0; }
/metadata:/ && !in_metadata { in_metadata = 1; next; }
/^ {6}labels:/ && in_metadata {
  print $0;
  print "      annotations:";
  print "        k8s.v1.cni.cncf.io/networks: |";
  print "          MULTUS_ANNOTATION";
  annotation_added = 1;
  next;
}
{ print $0; }
EOF
)
  
  awk -v multus="$PR_MULTUS" '{ gsub("MULTUS_ANNOTATION", multus); print }' <<< "$AWK_SCRIPT" > "$TEMP_FILE"
  
  # Use the script to modify the deployment file
  awk -f "$TEMP_FILE" "kustomize/base/shared/packetrusher/deployment.yaml" > "kustomize/base/shared/packetrusher/deployment.yaml.new"
  mv "kustomize/base/shared/packetrusher/deployment.yaml.new" "kustomize/base/shared/packetrusher/deployment.yaml"
  
  # Clean up
  rm "$TEMP_FILE"
  
  echo -e "${GREEN}Added Multus annotations to PacketRusher deployment.yaml${NC}"
fi

if [ -f "shared/packetrusher/service.yaml" ]; then
  cp "shared/packetrusher/service.yaml" "kustomize/base/shared/packetrusher/service.yaml"
  echo -e "${GREEN}Copied PacketRusher service.yaml${NC}"
fi

# Create PacketRusher kustomization.yaml
cat > kustomize/base/shared/packetrusher/kustomization.yaml << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml

configMapGenerator:
  - name: packetrusher-config
    files:
      - config.yml
EOF

echo -e "${GREEN}=== Migration to Kustomize structure with Multus completed! ===${NC}"
echo -e "${BLUE}Your Open5GS configuration has been migrated to kustomize/ directory${NC}"
echo -e "${BLUE}To deploy, run:${NC}"
echo -e "  ${YELLOW}microk8s kubectl apply -k kustomize/overlays/default${NC}"
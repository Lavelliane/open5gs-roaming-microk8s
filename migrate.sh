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

# Function to directly add Multus annotations 
add_multus_annotations() {
  local file=$1
  local annotations=$2
  
  echo -e "${BLUE}Adding Multus annotations to $file${NC}"
  
  # Create a temporary file
  local tmp_file=$(mktemp)
  
  # Use a simpler approach - find the line with "labels:" and add annotations
  while IFS= read -r line; do
    echo "$line" >> "$tmp_file"
    # Check if this line contains the labels section
    if [[ "$line" =~ "labels:" ]]; then
      echo "      annotations:" >> "$tmp_file"
      echo "        k8s.v1.cni.cncf.io/networks: |" >> "$tmp_file"
      echo "          $annotations" >> "$tmp_file"
    fi
  done < "$file"
  
  # Replace original file with modified file
  mv "$tmp_file" "$file"
  
  echo -e "${GREEN}Added Multus annotations to $file${NC}"
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

# Migrate SMF with Multus
migrate_component "visiting/smf" "kustomize/base/visiting/smf"

# Add Multus annotations to SMF
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

if [ -f "kustomize/base/visiting/smf/deployment.yaml" ]; then
  # Create SMF deployment with annotations
  cat > kustomize/base/visiting/smf/deployment.yaml.new << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: v-smf
  namespace: open5gs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: v-smf
  template:
    metadata:
      labels:
        app: v-smf
      annotations:
        k8s.v1.cni.cncf.io/networks: |
          $SMF_MULTUS
    spec:
      containers:
        - name: v-smf
          image: docker.io/library/smf:v2.7.5
          imagePullPolicy: IfNotPresent
          command: [ "open5gs-smfd", "-c", "/etc/open5gs/smf.yaml" ]
          volumeMounts:
            - name: config
              mountPath: /etc/open5gs/smf.yaml
              subPath: smf.yaml
          ports:
            - containerPort: 80
              name: sbi
              protocol: TCP
            - containerPort: 8805
              name: pfcp
              protocol: UDP
      volumes:
        - name: config
          configMap:
            name: v-smf-config
EOF
  mv kustomize/base/visiting/smf/deployment.yaml.new kustomize/base/visiting/smf/deployment.yaml
  echo -e "${GREEN}Created SMF deployment with Multus annotations${NC}"
fi

# Update SMF config
if [ -f "kustomize/base/visiting/smf/smf.yaml" ]; then
  # Use direct file editing
  cat > kustomize/base/visiting/smf/smf.yaml.new << EOF
logger:
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
  mtu: 1400
EOF
  mv kustomize/base/visiting/smf/smf.yaml.new kustomize/base/visiting/smf/smf.yaml
  echo -e "${GREEN}Updated SMF config with Multus IPs${NC}"
fi

# Migrate UPF
migrate_component "visiting/upf" "kustomize/base/visiting/upf"

# Add Multus annotations to UPF
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

if [ -f "kustomize/base/visiting/upf/deployment.yaml" ]; then
  # Create UPF deployment with annotations
  cat > kustomize/base/visiting/upf/deployment.yaml.new << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: v-upf
  namespace: open5gs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: v-upf
  template:
    metadata:
      labels:
        app: v-upf
      annotations:
        k8s.v1.cni.cncf.io/networks: |
          $UPF_MULTUS
    spec:
      containers:
        - name: v-upf
          image: docker.io/library/upf:v2.7.5
          imagePullPolicy: IfNotPresent 
          command: [ "open5gs-upfd", "-c", "/etc/open5gs/upf.yaml" ]
          securityContext:
            privileged: true
            capabilities:
              add: ["NET_ADMIN", "NET_RAW", "SYS_ADMIN"]
          volumeMounts:
            - name: config
              mountPath: /etc/open5gs/upf.yaml
              subPath: upf.yaml
            - name: dev-net-tun
              mountPath: /dev/net/tun
              readOnly: true
            - name: var-log
              mountPath: /var/log/open5gs
          ports:
            - name: pfcp
              containerPort: 8805
              protocol: UDP
            - name: gtpu
              containerPort: 2152
              protocol: UDP
      volumes:
        - name: config
          configMap:
            name: v-upf-config
        - name: dev-net-tun
          hostPath:
            path: /dev/net/tun
            type: CharDevice
        - name: var-log
          emptyDir: {}
EOF
  mv kustomize/base/visiting/upf/deployment.yaml.new kustomize/base/visiting/upf/deployment.yaml
  echo -e "${GREEN}Created UPF deployment with Multus annotations${NC}"
fi

# Update UPF config
if [ -f "kustomize/base/visiting/upf/upf.yaml" ]; then
  # Direct file editing
  cat > kustomize/base/visiting/upf/upf.yaml.new << EOF
logger:
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
      gateway: 10.45.0.1
EOF
  mv kustomize/base/visiting/upf/upf.yaml.new kustomize/base/visiting/upf/upf.yaml
  echo -e "${GREEN}Updated UPF config with Multus IPs${NC}"
fi

# Migrate AMF
migrate_component "visiting/amf" "kustomize/base/visiting/amf"

# Add Multus annotations to AMF
AMF_MULTUS='[
  {
    "name": "ngap-network",
    "interface": "ngap",
    "ips": ["192.168.30.101/24"]
  }
]'

if [ -f "kustomize/base/visiting/amf/deployment.yaml" ]; then
  # Create AMF deployment with annotations
  cat > kustomize/base/visiting/amf/deployment.yaml.new << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: v-amf
  namespace: open5gs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: v-amf
  template:
    metadata:
      labels:
        app: v-amf
      annotations:
        k8s.v1.cni.cncf.io/networks: |
          $AMF_MULTUS
    spec:
      containers:
        - name: v-amf
          image: docker.io/library/amf:v2.7.5
          imagePullPolicy: IfNotPresent
          command: [ "open5gs-amfd", "-c", "/etc/open5gs/amf.yaml" ]
          volumeMounts:
            - name: config
              mountPath: /etc/open5gs/amf.yaml
              subPath: amf.yaml
          ports:
            - containerPort: 80
              name: sbi
            - containerPort: 38412
              name: ngap
      volumes:
        - name: config
          configMap:
            name: v-amf-config
EOF
  mv kustomize/base/visiting/amf/deployment.yaml.new kustomize/base/visiting/amf/deployment.yaml
  echo -e "${GREEN}Created AMF deployment with Multus annotations${NC}"
fi

# Update AMF config
if [ -f "kustomize/base/visiting/amf/amf.yaml" ]; then
  # Direct file editing
  # Extract existing AMF config
  EXISTING_AMF_CONFIG=$(cat kustomize/base/visiting/amf/amf.yaml)
  # Replace the server address
  UPDATED_AMF_CONFIG=$(echo "$EXISTING_AMF_CONFIG" | sed 's/server:.*address: 0.0.0.0/server:\n          - address: 192.168.30.101/g')
  # Write updated config
  echo "$UPDATED_AMF_CONFIG" > kustomize/base/visiting/amf/amf.yaml
  echo -e "${GREEN}Updated AMF config with Multus IPs${NC}"
fi

# Migrate PacketRusher
mkdir -p kustomize/base/shared/packetrusher

# Create PacketRusher config from existing configmap
if [ -f "shared/packetrusher/configmap.yaml" ]; then
  # Extract config from ConfigMap
  grep -A 1000 "data:" "shared/packetrusher/configmap.yaml" | grep -v "data:" | sed '1d' > "kustomize/base/shared/packetrusher/config.yml"
  echo -e "${GREEN}Created PacketRusher config.yml${NC}"
  
  # Update the config to use the correct IPs
  sed -i "s/ip: '0.0.0.0'/ip: '192.168.30.102'/g" "kustomize/base/shared/packetrusher/config.yml"
  sed -i "s/ip: 'v-amf.open5gs.svc.cluster.local'/ip: '192.168.30.101'/g" "kustomize/base/shared/packetrusher/config.yml"
  echo -e "${GREEN}Updated PacketRusher config with Multus IPs${NC}"
fi

# Create PacketRusher deployment with Multus annotations
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

if [ -f "shared/packetrusher/deployment.yaml" ]; then
  # Create deployment file with annotations
  cat > kustomize/base/shared/packetrusher/deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: packetrusher
  namespace: open5gs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: packetrusher
  template:
    metadata:
      labels:
        app: packetrusher
      annotations:
        k8s.v1.cni.cncf.io/networks: |
          $PR_MULTUS
    spec:
      containers:
        - name: packetrusher
          image: ghcr.io/borjis131/packetrusher:20250225
          imagePullPolicy: IfNotPresent
          workingDir: /PacketRusher
          command: [ "./packetrusher", "ue" ]
          volumeMounts:
            - name: config
              mountPath: /PacketRusher/config/config.yml
              subPath: config.yml
          ports:
            - containerPort: 38412
              name: ngap
              protocol: UDP
            - containerPort: 2152
              name: gtpu
              protocol: UDP
          securityContext:
            privileged: true
            capabilities:
              add: ["NET_ADMIN"]
      volumes:
        - name: config
          configMap:
            name: packetrusher-config
EOF
  echo -e "${GREEN}Created PacketRusher deployment with Multus annotations${NC}"
fi

# Copy PacketRusher service
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
#!/bin/bash
# create-kustomize-structure.sh - Create a Kustomize structure for Open5GS deployment

set -e

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}Creating Kustomize structure for Open5GS deployment...${NC}"

# Create directory structure
mkdir -p kustomize/base/{mongodb,home,visiting,shared} kustomize/overlays/default

# Create kustomization.yaml files
cat <<EOF > kustomize/base/kustomization.yaml
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
cat <<EOF > kustomize/base/home/kustomization.yaml
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
cat <<EOF > kustomize/base/visiting/kustomization.yaml
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
cat <<EOF > kustomize/base/shared/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - packetrusher
EOF

# Create MongoDB kustomization
cat <<EOF > kustomize/base/mongodb/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - service.yaml
  - statefulset.yaml
EOF

# Create overlay kustomization
cat <<EOF > kustomize/overlays/default/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: open5gs

bases:
  - ../../base

# Add patches here for environment-specific customizations
EOF

echo -e "${GREEN}Kustomize directory structure created!${NC}"
echo -e "${BLUE}Now you need to copy your existing YAML files into the appropriate directories.${NC}"
echo -e "${BLUE}For example: cp shared/mongodb/service.yaml kustomize/base/mongodb/service.yaml${NC}"
#!/bin/bash

# Script to save Docker images and import them to microk8s
# Created: April 16, 2025

# Exit on error
set -e

# Display a message for each step
echo "Starting to save and import Docker images to microk8s..."

# Function to save and import an image
save_and_import() {
    local image=$1
    local tag=$2
    
    echo "Processing $image:$tag..."
    docker save $image:$tag | microk8s ctr image import -
    echo "Successfully imported $image:$tag to microk8s"
    echo "----------------------------------------"
}

# Process each image
save_and_import "udm" "v2.7.5"
save_and_import "smf" "v2.7.5"
save_and_import "amf" "v2.7.5"
save_and_import "pcf" "v2.7.5"
save_and_import "upf" "v2.7.5"
save_and_import "sepp" "v2.7.5"
save_and_import "scp" "v2.7.5"
save_and_import "ausf" "v2.7.5"
save_and_import "bsf" "v2.7.5"
save_and_import "nrf" "v2.7.5"
save_and_import "nssf" "v2.7.5"
save_and_import "udr" "v2.7.5"
save_and_import "base-open5gs" "v2.7.5"
save_and_import "webui" "v2.7.5"
save_and_import "ghcr.io/borjis131/packetrusher" "20250225"
save_and_import "mongo" "4.4"

echo "All images have been saved from Docker and imported to microk8s!"
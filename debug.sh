#!/bin/bash

# 5G Core Network Debugging Script
# This script helps diagnose common networking issues in a 5G core deployment

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
      echo "Usage: $0 [--namespace|-n NAMESPACE] "
      echo "  --namespace, -n: Specify the namespace to debug (default: open5gs)"
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

# Check that pods exist in the namespace
if ! microk8s kubectl get pods -n $NAMESPACE &> /dev/null; then
  echo -e "${RED}Error: No pods found in namespace $NAMESPACE${NC}"
  exit 1
fi

echo -e "${BLUE}========== 5G Core Network Debugging ===========${NC}"
echo -e "${BLUE}Namespace: $NAMESPACE${NC}"
echo -e "${BLUE}================================================${NC}"

# Function to check pod status
check_pod_status() {
  echo -e "${YELLOW}Checking pod status...${NC}"
  PODS=$(microk8s kubectl get pods -n $NAMESPACE -o wide)
  echo "$PODS"
  
  # Check for pods not in Running state
  NON_RUNNING=$(echo "$PODS" | grep -v "Running" | grep -v "NAME")
  if [ -n "$NON_RUNNING" ]; then
    echo -e "${RED}Found pods not in Running state:${NC}"
    echo "$NON_RUNNING"
    
    # Get details for non-running pods
    echo -e "${YELLOW}Getting details for non-running pods...${NC}"
    echo "$NON_RUNNING" | awk '{print $1}' | while read pod; do
      echo -e "${BLUE}==== Details for pod $pod ====${NC}"
      microk8s kubectl describe pod $pod -n $NAMESPACE
      echo -e "${BLUE}==== Logs for pod $pod ====${NC}"
      microk8s kubectl logs $pod -n $NAMESPACE --tail=50
    done
  else
    echo -e "${GREEN}All pods are running${NC}"
  fi
  
  echo -e "----------------------------------------"
}

# Function to check Multus CNI status
check_multus_status() {
  echo -e "${YELLOW}Checking Multus CNI status...${NC}"
  
  # Check if Multus pods are running
  MULTUS_PODS=$(microk8s kubectl get pods -n kube-system | grep multus)
  if [ -z "$MULTUS_PODS" ]; then
    echo -e "${RED}Error: Multus CNI pods not found${NC}"
  else
    echo -e "${GREEN}Multus CNI pods:${NC}"
    echo "$MULTUS_PODS"
  fi
  
  # Check NetworkAttachmentDefinitions
  echo -e "${YELLOW}Checking NetworkAttachmentDefinitions...${NC}"
  NAD=$(microk8s kubectl get networkattachmentdefinition -n $NAMESPACE 2>/dev/null)
  if [ $? -ne 0 ]; then
    echo -e "${RED}Error: NetworkAttachmentDefinitions CRD not found${NC}"
    echo -e "${YELLOW}Multus CNI might not be properly installed${NC}"
  else
    echo "$NAD"
  fi
  
  echo -e "----------------------------------------"
}

# Function to check SMF-UPF connectivity
check_smf_upf_connectivity() {
  echo -e "${YELLOW}Checking SMF-UPF PFCP connectivity...${NC}"
  
  # Get SMF and UPF pod names
  SMF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-smf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  UPF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-upf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [ -z "$SMF_POD" ] || [ -z "$UPF_POD" ]; then
    echo -e "${RED}Error: SMF or UPF pod not found${NC}"
  else
    echo -e "${BLUE}SMF Pod: $SMF_POD${NC}"
    echo -e "${BLUE}UPF Pod: $UPF_POD${NC}"
    
    # Check SMF network interfaces
    echo -e "${YELLOW}SMF network interfaces:${NC}"
    microk8s kubectl exec -n $NAMESPACE $SMF_POD -- ip addr | grep -E "eth|pfcp|gtpu"
    
    # Check UPF network interfaces
    echo -e "${YELLOW}UPF network interfaces:${NC}"
    microk8s kubectl exec -n $NAMESPACE $UPF_POD -- ip addr | grep -E "eth|pfcp|gtpu"
    
    # Try pinging UPF from SMF using PFCP interface
    echo -e "${YELLOW}Testing ping from SMF to UPF (PFCP)...${NC}"
    SMF_PING=$(microk8s kubectl exec -n $NAMESPACE $SMF_POD -- ping -c 2 192.168.10.101 2>&1)
    if echo "$SMF_PING" | grep -q "2 received"; then
      echo -e "${GREEN}SMF can ping UPF on PFCP network${NC}"
    else
      echo -e "${RED}SMF cannot ping UPF on PFCP network${NC}"
      echo "$SMF_PING"
    fi
    
    # Check PFCP trace in UPF
    echo -e "${YELLOW}Checking PFCP packets on UPF...${NC}"
    microk8s kubectl exec -n $NAMESPACE $UPF_POD -- tcpdump -i pfcp -n udp port 8805 -c 5 -t &
    TCPDUMP_PID=$!
    
    # Send PFCP heartbeat from SMF 
    echo -e "${YELLOW}Triggering PFCP message from SMF...${NC}"
    microk8s kubectl exec -n $NAMESPACE $SMF_POD -- pkill -SIGUSR1 open5gs-smfd
    
    # Wait for tcpdump to finish
    sleep 5
    kill $TCPDUMP_PID 2>/dev/null
    
    # Check SMF logs for PFCP association
    echo -e "${YELLOW}Checking SMF logs for PFCP association...${NC}"
    microk8s kubectl logs -n $NAMESPACE $SMF_POD --tail=50 | grep -i "pfcp"
    
    # Check UPF logs for PFCP association
    echo -e "${YELLOW}Checking UPF logs for PFCP association...${NC}"
    microk8s kubectl logs -n $NAMESPACE $UPF_POD --tail=50 | grep -i "pfcp"
  fi
  
  echo -e "----------------------------------------"
}

# Function to check AMF-PacketRusher connectivity
check_amf_gnb_connectivity() {
  echo -e "${YELLOW}Checking AMF-PacketRusher NGAP connectivity...${NC}"
  
  # Get AMF and PacketRusher pod names
  AMF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-amf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  PR_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=packetrusher -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [ -z "$AMF_POD" ] || [ -z "$PR_POD" ]; then
    echo -e "${RED}Error: AMF or PacketRusher pod not found${NC}"
  else
    echo -e "${BLUE}AMF Pod: $AMF_POD${NC}"
    echo -e "${BLUE}PacketRusher Pod: $PR_POD${NC}"
    
    # Check AMF network interfaces
    echo -e "${YELLOW}AMF network interfaces:${NC}"
    microk8s kubectl exec -n $NAMESPACE $AMF_POD -- ip addr | grep -E "eth|ngap"
    
    # Check PacketRusher network interfaces
    echo -e "${YELLOW}PacketRusher network interfaces:${NC}"
    microk8s kubectl exec -n $NAMESPACE $PR_POD -- ip addr | grep -E "eth|ngap|gtpu"
    
    # Try pinging AMF from PacketRusher using NGAP interface
    echo -e "${YELLOW}Testing ping from PacketRusher to AMF (NGAP)...${NC}"
    PR_PING=$(microk8s kubectl exec -n $NAMESPACE $PR_POD -- ping -c 2 192.168.30.101 2>&1)
    if echo "$PR_PING" | grep -q "2 received"; then
      echo -e "${GREEN}PacketRusher can ping AMF on NGAP network${NC}"
    else
      echo -e "${RED}PacketRusher cannot ping AMF on NGAP network${NC}"
      echo "$PR_PING"
    fi
    
    # Check AMF logs
    echo -e "${YELLOW}Checking AMF logs for NGAP/UE connections...${NC}"
    microk8s kubectl logs -n $NAMESPACE $AMF_POD --tail=100 | grep -E "NGAP|UE|5GMM"
    
    # Check PacketRusher logs
    echo -e "${YELLOW}Checking PacketRusher logs...${NC}"
    microk8s kubectl logs -n $NAMESPACE $PR_POD --tail=100 | grep -E "Registration|5GMM|attach"
  fi
  
  echo -e "----------------------------------------"
}

# Function to check NRF registrations
check_nrf_registrations() {
  echo -e "${YELLOW}Checking NRF service registrations...${NC}"
  
  # Get NRF pod names
  HNRF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=h-nrf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  VNRF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-nrf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [ -z "$HNRF_POD" ] || [ -z "$VNRF_POD" ]; then
    echo -e "${RED}Error: Home or Visiting NRF pod not found${NC}"
  else
    echo -e "${BLUE}Home NRF Pod: $HNRF_POD${NC}"
    echo -e "${BLUE}Visiting NRF Pod: $VNRF_POD${NC}"
    
    # Check Home NRF logs
    echo -e "${YELLOW}Checking Home NRF logs for service registrations...${NC}"
    microk8s kubectl logs -n $NAMESPACE $HNRF_POD --tail=50 | grep -i "register"
    
    # Check Visiting NRF logs
    echo -e "${YELLOW}Checking Visiting NRF logs for service registrations...${NC}"
    microk8s kubectl logs -n $NAMESPACE $VNRF_POD --tail=50 | grep -i "register"
    
    # Use NRF API to check registered NFs (Home)
    echo -e "${YELLOW}Checking registered NFs in Home NRF...${NC}"
    microk8s kubectl exec -n $NAMESPACE $HNRF_POD -- curl -s 127.0.0.1:80/nnrf-nfm/v1/nf-instances | grep -E "nfInstanceId|nfType" | head -n 20
    
    # Use NRF API to check registered NFs (Visiting)
    echo -e "${YELLOW}Checking registered NFs in Visiting NRF...${NC}"
    microk8s kubectl exec -n $NAMESPACE $VNRF_POD -- curl -s 127.0.0.1:80/nnrf-nfm/v1/nf-instances | grep -E "nfInstanceId|nfType" | head -n 20
  fi
  
  echo -e "----------------------------------------"
}

# Function to check MongoDB status and subscribers
check_mongodb() {
  echo -e "${YELLOW}Checking MongoDB status and subscribers...${NC}"
  
  # Get MongoDB pod name
  MONGODB_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=mongodb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [ -z "$MONGODB_POD" ]; then
    echo -e "${RED}Error: MongoDB pod not found${NC}"
  else
    echo -e "${BLUE}MongoDB Pod: $MONGODB_POD${NC}"
    
    # Check MongoDB status
    echo -e "${YELLOW}Checking MongoDB status...${NC}"
    MONGODB_STATUS=$(microk8s kubectl exec -n $NAMESPACE $MONGODB_POD -- mongo --eval "db.serverStatus()" 2>&1)
    if echo "$MONGODB_STATUS" | grep -q "ok : 1"; then
      echo -e "${GREEN}MongoDB is running properly${NC}"
    else
      echo -e "${RED}MongoDB status check failed${NC}"
      echo "$MONGODB_STATUS" | head -n 20
    fi
    
    # Count subscribers
    echo -e "${YELLOW}Checking subscriber count...${NC}"
    SUBSCRIBER_COUNT=$(microk8s kubectl exec -n $NAMESPACE $MONGODB_POD -- mongo --quiet --eval "db = db.getSiblingDB('open5gs'); db.subscribers.count()" 2>&1)
    echo -e "${BLUE}Subscriber count: $SUBSCRIBER_COUNT${NC}"
    
    if [ "$SUBSCRIBER_COUNT" -eq 0 ]; then
      echo -e "${RED}No subscribers found in the database${NC}"
    else
      # Show one subscriber for verification
      echo -e "${YELLOW}Sample subscriber data:${NC}"
      microk8s kubectl exec -n $NAMESPACE $MONGODB_POD -- mongo --quiet --eval "db = db.getSiblingDB('open5gs'); db.subscribers.findOne()" | grep -E "imsi|k\"\ :|opc\"\ :"
    fi
  fi
  
  echo -e "----------------------------------------"
}

# Function to check overall service status
check_services_status() {
  echo -e "${YELLOW}Checking service status...${NC}"
  
  # Get all services
  SERVICES=$(microk8s kubectl get services -n $NAMESPACE)
  echo "$SERVICES"
  
  # Check endpoints
  echo -e "${YELLOW}Checking service endpoints...${NC}"
  microk8s kubectl get endpoints -n $NAMESPACE
  
  echo -e "----------------------------------------"
}

# Function to check Multus pod annotations
check_multus_annotations() {
  echo -e "${YELLOW}Checking Multus pod annotations...${NC}"
  
  # Check key pods for Multus annotations
  for pod_type in "v-smf" "v-upf" "v-amf" "packetrusher"; do
    POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=$pod_type -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$POD" ]; then
      echo -e "${BLUE}Checking $pod_type pod ($POD) annotations:${NC}"
      microk8s kubectl get pod $POD -n $NAMESPACE -o jsonpath='{.metadata.annotations}' | grep -i "k8s.v1.cni.cncf.io/networks"
    fi
  done
  
  echo -e "----------------------------------------"
}

# Execute all checks
check_pod_status
check_multus_status
check_multus_annotations
check_services_status
check_mongodb
check_nrf_registrations
check_smf_upf_connectivity
check_amf_gnb_connectivity

echo -e "${GREEN}=============== DEBUG SUMMARY ================${NC}"

# Check for common issues
COMMON_ISSUES=0

# Check if Multus is properly installed
if ! microk8s kubectl get pods -n kube-system | grep -q "multus"; then
  echo -e "${RED}[ISSUE] Multus CNI is not installed or running${NC}"
  echo -e "${YELLOW}Solution: Run ./setup-multus.sh to install Multus CNI${NC}"
  COMMON_ISSUES=$((COMMON_ISSUES + 1))
fi

# Check if NetworkAttachmentDefinitions are created
if ! microk8s kubectl get networkattachmentdefinition -n $NAMESPACE &>/dev/null; then
  echo -e "${RED}[ISSUE] NetworkAttachmentDefinitions are missing${NC}"
  echo -e "${YELLOW}Solution: Run ./setup-multus.sh to create required network definitions${NC}"
  COMMON_ISSUES=$((COMMON_ISSUES + 1))
fi

# Check if SMF and UPF are both running
SMF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-smf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
UPF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-upf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$SMF_POD" ] || [ -z "$UPF_POD" ]; then
  echo -e "${RED}[ISSUE] SMF or UPF pod is missing${NC}"
  echo -e "${YELLOW}Solution: Deploy both SMF and UPF components${NC}"
  COMMON_ISSUES=$((COMMON_ISSUES + 1))
else
  # Check PFCP connectivity
  SMF_PING=$(microk8s kubectl exec -n $NAMESPACE $SMF_POD -- ping -c 2 192.168.10.101 2>&1 || echo "fail")
  if ! echo "$SMF_PING" | grep -q "2 received"; then
    echo -e "${RED}[ISSUE] SMF cannot communicate with UPF over PFCP network${NC}"
    echo -e "${YELLOW}Solution: Check Multus CNI setup and pod annotations for PFCP network${NC}"
    COMMON_ISSUES=$((COMMON_ISSUES + 1))
  fi
fi

# Check MongoDB subscriber entries
MONGODB_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=mongodb -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$MONGODB_POD" ]; then
  SUBSCRIBER_COUNT=$(microk8s kubectl exec -n $NAMESPACE $MONGODB_POD -- mongo --quiet --eval "db = db.getSiblingDB('open5gs'); db.subscribers.count()" 2>&1 || echo "0")
  if [ "$SUBSCRIBER_COUNT" -eq 0 ]; then
    echo -e "${RED}[ISSUE] No subscribers found in MongoDB${NC}"
    echo -e "${YELLOW}Solution: Add subscribers to MongoDB using the add-subscriber script${NC}"
    COMMON_ISSUES=$((COMMON_ISSUES + 1))
  fi
fi

# Check AMF and PacketRusher connectivity
AMF_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=v-amf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
PR_POD=$(microk8s kubectl get pods -n $NAMESPACE -l app=packetrusher -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$AMF_POD" ] && [ -n "$PR_POD" ]; then
  PR_PING=$(microk8s kubectl exec -n $NAMESPACE $PR_POD -- ping -c 2 192.168.30.101 2>&1 || echo "fail")
  if ! echo "$PR_PING" | grep -q "2 received"; then
    echo -e "${RED}[ISSUE] PacketRusher cannot communicate with AMF over NGAP network${NC}"
    echo -e "${YELLOW}Solution: Check Multus CNI setup and pod annotations for NGAP network${NC}"
    COMMON_ISSUES=$((COMMON_ISSUES + 1))
  fi
fi

# Display conclusion
if [ $COMMON_ISSUES -eq 0 ]; then
  echo -e "${GREEN}No common issues detected. If you're still experiencing problems, check the specific component logs.${NC}"
else
  echo -e "${RED}Found $COMMON_ISSUES common issues. Please fix them and run this script again.${NC}"
fi

echo -e "${BLUE}================================================${NC}"
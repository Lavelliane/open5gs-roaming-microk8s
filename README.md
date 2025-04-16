# K8s Deployment

This repository contains Kubernetes deployment configurations for applications.

## Prerequisites

### MicroK8s Installation

#### Ubuntu/Debian
```bash
sudo snap install microk8s --classic
sudo usermod -a -G microk8s $USER
sudo chown -f -R $USER ~/.kube
newgrp microk8s
```

#### Windows
1. Install [Multipass](https://multipass.run/) or enable WSL2
2. Using Multipass:
```bash
multipass launch --name microk8s-vm --memory 4G --disk 40G
multipass exec microk8s-vm -- sudo snap install microk8s --classic
multipass exec microk8s-vm -- sudo usermod -a -G microk8s ubuntu
multipass exec microk8s-vm -- sudo chown -f -R ubuntu ~/.kube
multipass shell microk8s-vm
```

#### macOS
```bash
brew install ubuntu/microk8s/microk8s
microk8s install
```

### Verify Installation
```bash
microk8s status --wait-ready
```

## Setup MicroK8s

### 1. Set up MicroK8s essentials

Ensure MicroK8s has these services enabled:
```bash
microk8s enable dns storage helm3
```

You'll also need:
```bash
microk8s kubectl create namespace open5gs
```

Optional (for ingress):
```bash
microk8s enable ingress
```

### Using MicroK8s

Access kubectl:
```bash
microk8s kubectl [command]
```

Or create an alias:
```bash
alias kubectl='microk8s kubectl'
```

## Deployment

[Add deployment instructions here]

## Troubleshooting

[Add troubleshooting steps here]

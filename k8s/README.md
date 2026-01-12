# RomM Kubernetes Deployment Guide

This guide covers deploying RomM microservices to a local k3d cluster for testing Kubernetes deployments.

## Prerequisites

- Docker Desktop for Mac (running)
- k3d installed (`brew install k3d`)
- kubectl installed (`brew install kubectl`)

## Quick Start

### Option 1: Automated Deployment (Recommended)

Use the deployment script to automatically create cluster, build images, and deploy:

```bash
./deploy-k3d.sh
```

This will:
1. Create a k3d cluster named "romm"
2. Create a local Docker registry
3. Build frontend and backend images
4. Push images to the local registry
5. Deploy all Kubernetes resources
6. Show deployment status

### Option 2: Manual Step-by-Step

#### 1. Create k3d Cluster

```bash
# Create local registry
k3d registry create registry.localhost --port 5000

# Create cluster with registry
k3d cluster create romm \
    --registry-use k3d-registry.localhost:5000 \
    --port "8080:80@loadbalancer" \
    --agents 1
```

#### 2. Build and Push Images

```bash
# Build frontend image
docker build \
    -f docker/Dockerfile.frontend \
    --target frontend-slim \
    -t localhost:5000/romm-frontend:latest \
    .

# Build backend image
docker build \
    -f docker/Dockerfile.backend \
    --target backend-slim \
    -t localhost:5000/romm-backend:latest \
    .

# Push images to local registry
docker push localhost:5000/romm-frontend:latest
docker push localhost:5000/romm-backend:latest
```

#### 3. Deploy to Kubernetes

```bash
# Apply manifests in order
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/storage.yaml
kubectl apply -f k8s/database.yaml
kubectl apply -f k8s/valkey.yaml

# Wait for database to be ready
kubectl wait --for=condition=Ready pod -l app=romm-db -n romm --timeout=180s

# Deploy backend and frontend
kubectl apply -f k8s/backend.yaml
kubectl apply -f k8s/frontend.yaml
```

## Accessing the Application

### For k3d (Local Development)

When creating the cluster with `--port "8080:80@loadbalancer"`, the LoadBalancer service is automatically mapped to your local machine.

Access RomM at: **http://localhost:8080**

No port-forwarding needed! The k3d port mapping handles this automatically.

### For Production Kubernetes

For production clusters with LoadBalancer support (AWS ELB, GCP LB, Azure LB, etc.), get the external IP:

```bash
kubectl get svc -n romm romm-frontend
```

The `EXTERNAL-IP` column will show the public IP or hostname where you can access RomM.

### Alternative: Port Forwarding

If you didn't create the cluster with port mapping, you can use port-forwarding (note: not recommended for large file transfers like ROM files):

```bash
kubectl port-forward -n romm svc/romm-frontend 8080:80
```

**Important Note**: This deployment does not include an ingress controller. Users should configure their own ingress/egress solution based on their cluster requirements (nginx-ingress, Traefik, Istio, etc.)

## Useful Commands

### Check Deployment Status

```bash
# All resources
kubectl get all -n romm

# Pods
kubectl get pods -n romm

# Services
kubectl get svc -n romm

# Persistent Volume Claims
kubectl get pvc -n romm
```

### View Logs

```bash
# Frontend logs
kubectl logs -n romm -l app=romm-frontend --tail=50 -f

# Backend logs
kubectl logs -n romm -l app=romm-backend --tail=50 -f

# Database logs
kubectl logs -n romm -l app=romm-db --tail=50 -f
```

### Debug

```bash
# Get pod details
kubectl describe pod -n romm <pod-name>

# Execute commands in pod
kubectl exec -it -n romm <pod-name> -- /bin/sh

# Get events
kubectl get events -n romm --sort-by='.lastTimestamp'
```

### Scale Services

```bash
# Scale frontend
kubectl scale deployment romm-frontend -n romm --replicas=3

# Scale backend
kubectl scale deployment romm-backend -n romm --replicas=2
```

## Configuration

### Update ConfigMap

Edit `k8s/configmap.yaml` and apply:

```bash
kubectl apply -f k8s/configmap.yaml
kubectl rollout restart deployment -n romm romm-backend romm-frontend
```

### Update Secrets

Edit `k8s/configmap.yaml` (Secret section) and apply:

```bash
kubectl apply -f k8s/configmap.yaml
kubectl rollout restart deployment -n romm romm-backend
```

### RomM Application Configuration (config.yml)

The backend deployment automatically creates a default `config.yml` file in the `romm-config` PVC on first startup. This file configures:

- **EmulatorJS settings** (enabled by default)
- **Scan priorities** (metadata sources, regions, languages)
- **Filesystem settings** (ROM folder structure)

The config file is created by an initContainer if it doesn't exist, ensuring:
- ✅ No "Configuration file not mounted!" warning
- ✅ EmulatorJS works out of the box
- ✅ User changes are preserved across restarts

#### Editing config.yml

**Option 1: Edit in running pod**
```bash
kubectl exec -n romm deployment/romm-backend -- vi /romm/config/config.yml
kubectl rollout restart deployment -n romm romm-backend
```

**Option 2: Copy locally, edit, copy back**
```bash
# Get current pod name
POD=$(kubectl get pod -n romm -l app=romm-backend -o jsonpath='{.items[0].metadata.name}')

# Copy config locally
kubectl cp romm/$POD:/romm/config/config.yml ./config.yml

# Edit the file
vi config.yml

# Copy back
kubectl cp ./config.yml romm/$POD:/romm/config/config.yml

# Restart backend
kubectl rollout restart deployment -n romm romm-backend
```

**Option 3: View example configuration**
See `examples/config.example.yml` in the repository for all available options including:
- EmulatorJS per-core settings and control mappings
- Netplay configuration with STUN/TURN servers
- Platform exclusions and custom bindings
- Media asset types to download

#### Resetting to defaults

Delete the config file and restart to recreate with defaults:
```bash
kubectl exec -n romm deployment/romm-backend -- rm /romm/config/config.yml
kubectl delete pod -n romm -l app=romm-backend
```

## Storage Notes

### PVC Access Modes

The deployment uses several PVCs with different access modes:

- **ReadWriteOnce (RWO)**: Database, Valkey
  - Can only be mounted by one node
  - Works with k3d's local-path provisioner

- **ReadWriteMany (RWX)**: Library, Resources, Assets, Config
  - Can be mounted by multiple nodes
  - **Important**: k3d's default `local-path` provisioner doesn't support RWX

### For Production Kubernetes

For real Kubernetes clusters with multiple nodes, you'll need a storage class that supports RWX:

- **NFS**: Classic shared filesystem
- **CephFS**: Distributed storage
- **GlusterFS**: Distributed storage
- **Cloud providers**:
  - AWS: EFS (Elastic File System)
  - GCP: Filestore
  - Azure: Azure Files

### For k3d Testing (Single Node)

The default `local-path` provisioner works because k3d runs a single-node cluster. All pods can access the same local path.

If you encounter issues, you can install an NFS provisioner:

```bash
# Install NFS provisioner
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
helm install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --set nfs.server=<your-nfs-server> \
    --set nfs.path=/path/to/nfs
```

## Updating Images

### Rebuild and Redeploy

```bash
# Use deployment script
./deploy-k3d.sh build

# Or manually
docker build -f docker/Dockerfile.frontend --target frontend-slim -t localhost:5000/romm-frontend:latest .
docker push localhost:5000/romm-frontend:latest

docker build -f docker/Dockerfile.backend --target backend-slim -t localhost:5000/romm-backend:latest .
docker push localhost:5000/romm-backend:latest

# Restart deployments
kubectl rollout restart deployment -n romm romm-frontend
kubectl rollout restart deployment -n romm romm-backend
```

## Cleanup

### Delete Everything

```bash
# Using script
./deploy-k3d.sh clean

# Or manually
kubectl delete namespace romm
k3d cluster delete romm
k3d registry delete k3d-registry.localhost
```

## Troubleshooting

### Pods in Pending State

Check PVC status:
```bash
kubectl get pvc -n romm
```

Check events:
```bash
kubectl get events -n romm --sort-by='.lastTimestamp'
```

### ImagePullBackOff Errors

Verify images exist in registry:
```bash
curl http://localhost:5000/v2/_catalog
curl http://localhost:5000/v2/romm-frontend/tags/list
curl http://localhost:5000/v2/romm-backend/tags/list
```

### Database Connection Errors

Check if database is ready:
```bash
kubectl get pods -n romm -l app=romm-db
kubectl logs -n romm -l app=romm-db
```

Test database connection from backend pod:
```bash
kubectl exec -it -n romm <backend-pod> -- /bin/sh
# Inside pod:
ping romm-db
nc -zv romm-db 3306
```

### Frontend Can't Reach Backend

Check backend service:
```bash
kubectl get svc -n romm romm-backend
```

Test from frontend pod:
```bash
kubectl exec -it -n romm <frontend-pod> -- /bin/sh
# Inside pod:
ping romm-backend
wget -O- http://romm-backend:5000/api/heartbeat
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│              k3d Cluster (romm)                         │
│                                                          │
│  ┌────────────────┐         ┌──────────────────────┐   │
│  │  Frontend      │────────▶│  Backend             │   │
│  │  Deployment    │         │  Deployment          │   │
│  │  (1 replica)   │         │  (1 replica)         │   │
│  │                │         │                      │   │
│  │  - nginx       │         │  - FastAPI           │   │
│  │  - Vue.js SPA  │         │  - RQ Worker         │   │
│  └────────────────┘         │  - RQ Scheduler      │   │
│         │                   │  - Watcher           │   │
│         │                   └──────────────────────┘   │
│         │                            │                 │
│         │                   ┌────────┴─────────┐       │
│         │                   │                  │       │
│  ┌──────▼──────┐     ┌──────▼─────┐   ┌───────▼────┐  │
│  │  LoadBalancer   │  Valkey    │   │  MariaDB   │  │
│  │  Service    │     │  Deployment│   │  Deployment│  │
│  │             │     │  (1 replica)   │  (1 replica)   │
│  └─────────────┘     └────────────┘   └────────────┘  │
│         │                   │                  │       │
│         │                   ▼                  ▼       │
│         │            ┌──────────┐      ┌──────────┐   │
│         │            │  PVC     │      │  PVC     │   │
│         │            │  1Gi     │      │  10Gi    │   │
│         │            └──────────┘      └──────────┘   │
│         │                                              │
│         │            ┌──────────────────────────┐     │
│         │            │  Shared PVCs (RWX)       │     │
│         │            │  - Library (50Gi)        │     │
│         │            │  - Resources (5Gi)       │     │
│         │            │  - Assets (5Gi)          │     │
│         │            │  - Config (1Gi)          │     │
│         │            └──────────────────────────┘     │
│         │                                              │
└─────────┼──────────────────────────────────────────────┘
          │
          ▼
    Port Forward or External LoadBalancer IP
```

## Next Steps

Once you've validated the deployment works in k3d:

1. **Adapt for production Kubernetes**:
   - Change image references from `localhost:5000` to your container registry
   - Configure RWX-capable storage class for multi-node clusters
   - **Set up ingress/egress control** based on your requirements:
     - Install and configure an ingress controller (nginx-ingress, Traefik, Istio, etc.)
     - Create Ingress resources to route traffic to the frontend LoadBalancer
     - Configure TLS/SSL certificates
     - Set up rate limiting, WAF, and other security policies
   - Configure resource limits based on load testing
   - Set up monitoring (Prometheus + Grafana)

2. **CI/CD Integration**:
   - Build images in CI pipeline
   - Push to container registry (Docker Hub, GHCR, ECR, etc.)
   - Deploy via GitOps (ArgoCD, Flux)

3. **Production Hardening**:
   - Enable Pod Security Standards
   - Configure Network Policies to control ingress/egress traffic
   - Set up RBAC
   - Enable audit logging
   - Configure backup strategy for PVCs

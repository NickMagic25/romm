#!/bin/bash

# RomM k3d Deployment Script
# This script sets up a local k3d cluster and deploys RomM microservices
#
# Usage:
#   ./deploy-k3d.sh          # Create cluster, build, and deploy
#   ./deploy-k3d.sh build    # Only build images
#   ./deploy-k3d.sh deploy   # Only deploy (assumes images exist)
#   ./deploy-k3d.sh clean    # Delete cluster and clean up
#
# Important Notes:
#   - Uses port 5001 to avoid macOS AirPlay Receiver on port 5000
#   - Images are tagged for both localhost and k3d-registry for cluster access
#   - k8s/storage.yaml uses ReadWriteOnce (RWO) for k3d local-path compatibility
#   - k8s/database.yaml uses mariadb-admin (not mysqladmin) for MariaDB 11.3.2
#   - Frontend accessible via LoadBalancer on localhost:8080 (k3d port mapping)
#   - No ingress controller included - users should configure their own ingress/egress

set -e

CLUSTER_NAME="romm"
REGISTRY_NAME="registry.localhost"  # k3d will prefix with "k3d-"
REGISTRY_PORT="5001"  # Using 5001 to avoid macOS AirPlay on port 5000
REGISTRY_HOST="k3d-registry.localhost"  # Registry host used inside k3d cluster

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}==>${NC} $1"
}

create_cluster() {
    log_step "Creating k3d cluster with local registry"

    # Check if cluster already exists
    if k3d cluster list | grep -q "${CLUSTER_NAME}"; then
        log_warn "Cluster '${CLUSTER_NAME}' already exists, skipping creation"
        return 0
    fi

    # Create registry if it doesn't exist
    if ! k3d registry list | grep -q "k3d-${REGISTRY_NAME}"; then
        log_info "Creating local Docker registry..."
        k3d registry create ${REGISTRY_NAME} --port ${REGISTRY_PORT}
    fi

    # Create cluster with registry
    log_info "Creating k3d cluster..."
    k3d cluster create ${CLUSTER_NAME} \
        --registry-use k3d-${REGISTRY_NAME}:${REGISTRY_PORT} \
        --port "8080:80@loadbalancer" \
        --volume "$(pwd)/romm_mock/library:/mnt/romm-library@server:0" \
        --volume "$(pwd)/romm_mock/library:/mnt/romm-library@agent:0" \
        --agents 1

    log_info "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=120s

    log_info "✓ Cluster created successfully"
}

build_images() {
    log_step "Building Docker images"

    cd "$(dirname "$0")"

    log_info "Building frontend image (full with EmulatorJS)..."
    docker build \
        -f docker/Dockerfile.frontend \
        --target frontend-full \
        -t localhost:${REGISTRY_PORT}/romm-frontend:latest \
        -t ${REGISTRY_HOST}:${REGISTRY_PORT}/romm-frontend:latest \
        .

    log_info "Building backend image (production)..."
    docker build \
        -f docker/Dockerfile.backend \
        --target backend-production \
        -t localhost:${REGISTRY_PORT}/romm-backend:latest \
        -t ${REGISTRY_HOST}:${REGISTRY_PORT}/romm-backend:latest \
        .

    log_info "✓ Images built successfully"
    log_info "   Tagged for localhost and k3d-registry access"
}

push_images() {
    log_step "Pushing images to k3d registry"

    log_info "Pushing frontend image (localhost tag)..."
    docker push localhost:${REGISTRY_PORT}/romm-frontend:latest

    log_info "Pushing frontend image (k3d-registry tag)..."
    docker push ${REGISTRY_HOST}:${REGISTRY_PORT}/romm-frontend:latest

    log_info "Pushing backend image (localhost tag)..."
    docker push localhost:${REGISTRY_PORT}/romm-backend:latest

    log_info "Pushing backend image (k3d-registry tag)..."
    docker push ${REGISTRY_HOST}:${REGISTRY_PORT}/romm-backend:latest

    log_info "✓ Images pushed successfully"
    log_info "   Both localhost and k3d-registry tags available"
}

deploy_app() {
    log_step "Deploying RomM to Kubernetes"

    log_info "Creating namespace..."
    kubectl apply -f k8s/namespace.yaml

    log_info "Creating ConfigMap and Secrets..."
    kubectl apply -f k8s/configmap.yaml

    log_info "Creating storage (PVCs)..."
    kubectl apply -f k8s/storage.yaml

    log_info "Deploying database..."
    kubectl apply -f k8s/database.yaml

    log_info "Deploying Valkey..."
    kubectl apply -f k8s/valkey.yaml

    log_info "Waiting for database to be ready..."
    kubectl wait --for=condition=Ready pod -l app=romm-db -n romm --timeout=180s

    log_info "Waiting for Valkey to be ready..."
    kubectl wait --for=condition=Ready pod -l app=romm-valkey -n romm --timeout=180s

    log_info "Deploying backend..."
    kubectl apply -f k8s/backend.yaml

    log_info "Waiting for backend to be ready..."
    kubectl wait --for=condition=Ready pod -l app=romm-backend -n romm --timeout=180s

    log_info "Deploying frontend..."
    kubectl apply -f k8s/frontend.yaml

    log_info "Waiting for frontend to be ready..."
    kubectl wait --for=condition=Ready pod -l app=romm-frontend -n romm --timeout=120s

    log_info "Deploying ingress..."
    kubectl apply -f k8s/ingress.yaml

    log_info "✓ Application deployed successfully"
}

show_status() {
    log_step "Deployment Status"

    echo ""
    echo "Pods:"
    kubectl get pods -n romm

    echo ""
    echo "Services:"
    kubectl get svc -n romm

    echo ""
    log_info "Access RomM at: http://localhost:8080"
    echo ""
    log_info "For production clusters with LoadBalancer support, get the external IP:"
    log_info "  kubectl get svc -n romm romm-frontend"
    echo ""
    log_info "To check logs:"
    log_info "  kubectl logs -n romm -l app=romm-frontend"
    log_info "  kubectl logs -n romm -l app=romm-backend"
    echo ""
}

clean() {
    log_step "Cleaning up k3d cluster"

    log_warn "This will delete the cluster and all data. Continue? (y/N)"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log_info "Cleanup cancelled"
        exit 0
    fi

    log_info "Deleting k3d cluster..."
    k3d cluster delete ${CLUSTER_NAME}

    log_info "Deleting registry..."
    k3d registry delete k3d-${REGISTRY_NAME}

    log_info "✓ Cleanup complete"
}

main() {
    case "${1:-all}" in
        build)
            build_images
            push_images
            ;;
        deploy)
            deploy_app
            show_status
            ;;
        clean)
            clean
            ;;
        slim)
            create_cluster
            build_images-slim
            push_images
            deploy_app
            show_status
            ;;
        dev)
            create_cluster
            build_images-dev
            push_images
            deploy_app
            show_status
            ;;
        all|*)
            create_cluster
            build_images
            push_images
            deploy_app
            show_status
            ;;
    esac
}

main "$@"

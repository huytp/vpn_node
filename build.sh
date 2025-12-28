#!/bin/bash

set -e

echo "🔨 Building VPN Node Docker image..."

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is not installed. Please install Docker first."
    exit 1
fi

# Build Docker image
IMAGE_NAME="vpn-node"
IMAGE_TAG="${1:-latest}"

echo "Building image: ${IMAGE_NAME}:${IMAGE_TAG}"

docker build -t ${IMAGE_NAME}:${IMAGE_TAG} .

echo ""
echo "✅ Docker image built successfully!"
echo ""
echo "To run the container:"
echo "  docker run -d --name vpn-node --network host --cap-add NET_ADMIN --cap-add SYS_MODULE --device /dev/net/tun -v \$(pwd)/keys:/app/keys:ro -v /etc/wireguard:/etc/wireguard:ro --env-file .env ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
echo "Or use docker-compose:"
echo "  docker-compose up -d"


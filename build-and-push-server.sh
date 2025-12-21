#!/bin/bash

set -e  # Exit on error

# Configuration
REGISTRY="registry.main.safemetrics.app"
IMAGE_NAME="woodpecker-server"
TAG=$(git rev-parse --short HEAD)
COMMIT_SHA=$(git rev-parse HEAD)
TARGETOS="linux"
TARGETARCH="amd64"
# Set these as environment variables before running:
# export REGISTRY_USERNAME=your_username
# export REGISTRY_PASSWORD=your_password

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE} Building Woodpecker Server Docker Image${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Registry: ${REGISTRY}"
echo -e "Image: ${IMAGE_NAME}:${TAG}"
echo -e "Platform: ${TARGETOS}/${TARGETARCH}"
echo ""

# Build Docker image using multi-stage Dockerfile
echo -e "${GREEN}Building Docker image with multi-stage build...${NC}"
docker build \
  --build-arg TARGETOS=${TARGETOS} \
  --build-arg TARGETARCH=${TARGETARCH} \
  --build-arg CI_COMMIT_SHA=${COMMIT_SHA} \
  -f docker/Dockerfile.server.build \
  -t ${REGISTRY}/${IMAGE_NAME}:${TAG} \
  -t ${IMAGE_NAME}:${TAG} \
  .

echo -e "\n${GREEN}Docker image built successfully!${NC}"
docker images | grep ${IMAGE_NAME}

# Step 2: Login to registry
echo -e "\n${GREEN}Logging into registry ${REGISTRY}...${NC}"
if [ -z "$REGISTRY_USERNAME" ] || [ -z "$REGISTRY_PASSWORD" ]; then
  echo -e "${BLUE}Warning: REGISTRY_USERNAME or REGISTRY_PASSWORD not set. Skipping push...${NC}"
  echo -e "\nTo push to registry, set the environment variables and run:"
  echo -e "  docker push ${REGISTRY}/${IMAGE_NAME}:${TAG}"
else
  echo "$REGISTRY_PASSWORD" | docker login ${REGISTRY} -u "$REGISTRY_USERNAME" --password-stdin
  echo -e "${GREEN}Login successful!${NC}"

  # Step 3: Push to registry
  echo -e "\n${GREEN}Pushing image to ${REGISTRY}...${NC}"
  docker push ${REGISTRY}/${IMAGE_NAME}:${TAG}

  echo -e "\n${BLUE}========================================${NC}"
  echo -e "${GREEN}Build and push completed successfully!${NC}"
  echo -e "${BLUE}========================================${NC}"
  echo -e "Image: ${REGISTRY}/${IMAGE_NAME}:${TAG}"
  echo -e "Commit: ${COMMIT_SHA}"
  echo -e "\nYou can now pull and run the image with:"
  echo -e "  docker pull ${REGISTRY}/${IMAGE_NAME}:${TAG}"
  echo -e "  docker run -d -p 8000:8000 ${REGISTRY}/${IMAGE_NAME}:${TAG}"
fi

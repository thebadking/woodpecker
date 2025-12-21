#!/bin/bash

set -e  # Exit on error

# Configuration
REGISTRY="registry.main.safemetrics.app"
IMAGE_NAME="woodpecker-server"
REMOTE_HOST="registry.main.safemetrics.app"
REMOTE_USER="dre"
# Set these as environment variables before running:
# export REGISTRY_USERNAME=your_username
# export REGISTRY_PASSWORD=your_password
# For SSH (optional, set if you want to automate garbage collection):
# export REGISTRY_CONTAINER_NAME=docker-registry  # Default, change if different

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to check if credentials are set
check_credentials() {
  if [ -z "$REGISTRY_USERNAME" ] || [ -z "$REGISTRY_PASSWORD" ]; then
    echo -e "${RED}Error: REGISTRY_USERNAME or REGISTRY_PASSWORD not set.${NC}"
    echo -e "${BLUE}Please enter them now.${NC}"
    read -p "Enter REGISTRY_USERNAME: " REGISTRY_USERNAME
    read -s -p "Enter REGISTRY_PASSWORD: " REGISTRY_PASSWORD
    echo ""
    if [ -z "$REGISTRY_USERNAME" ] || [ -z "$REGISTRY_PASSWORD" ]; then
      echo -e "${RED}Credentials required. Exiting.${NC}"
      exit 1
    fi
  fi
}

# Function to list tags from registry
list_tags() {
  check_credentials
  echo -e "${GREEN}Listing tags for ${REGISTRY}/${IMAGE_NAME}...${NC}"
  CURL_OUTPUT=$(curl -s -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" "https://${REGISTRY}/v2/${IMAGE_NAME}/tags/list")
  if [[ $CURL_OUTPUT == *"tags"* ]]; then
    TAGS=$(echo "$CURL_OUTPUT" | grep -oP '(?<="tags":\[)[^]]*' | tr -d '"' | tr ',' '\n')
    if [ -z "$TAGS" ]; then
      echo -e "${BLUE}No tags found.${NC}"
    else
      echo -e "${BLUE}Available tags:${NC}"
      echo "$TAGS"
    fi
  else
    echo -e "${RED}Failed to list tags. Check credentials or registry URL.${NC}"
    echo "Response: $CURL_OUTPUT"
  fi
}

# Function to delete a single tag (refactored)
delete_by_tag() {
  local DELETE_TAG="$1"
  echo -e "${GREEN}Deleting tag ${DELETE_TAG}...${NC}"

  # Fetch manifest using GET (HEAD is often not supported)
  RESPONSE_HEADERS=$(mktemp)
  RESPONSE_BODY=$(mktemp)

  HTTP_STATUS=$(curl -s \
    -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    -D "$RESPONSE_HEADERS" \
    -o "$RESPONSE_BODY" \
    -w "%{http_code}" \
    "https://${REGISTRY}/v2/${IMAGE_NAME}/manifests/${DELETE_TAG}")

  if [[ "$HTTP_STATUS" -ne 200 ]]; then
    echo -e "${RED}Failed to fetch manifest for tag ${DELETE_TAG}. HTTP status: ${HTTP_STATUS}${NC}"
    cat "$RESPONSE_BODY"
    rm -f "$RESPONSE_HEADERS" "$RESPONSE_BODY"
    return 1
  fi

  DIGEST=$(grep -i Docker-Content-Digest "$RESPONSE_HEADERS" | awk '{print $2}' | tr -d '\r')

  if [ -z "$DIGEST" ]; then
    echo -e "${RED}Failed to extract digest for tag ${DELETE_TAG}.${NC}"
    cat "$RESPONSE_HEADERS"
    rm -f "$RESPONSE_HEADERS" "$RESPONSE_BODY"
    return 1
  fi

  echo -e "${GREEN}Resolved digest: ${DIGEST}${NC}"

  DELETE_STATUS=$(curl -s \
    -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" \
    -X DELETE \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    -o /dev/null \
    -w "%{http_code}" \
    "https://${REGISTRY}/v2/${IMAGE_NAME}/manifests/${DIGEST}")

  rm -f "$RESPONSE_HEADERS" "$RESPONSE_BODY"

  if [[ "$DELETE_STATUS" -ge 200 && "$DELETE_STATUS" -lt 300 ]]; then
    echo -e "${GREEN}Tag ${DELETE_TAG} deleted successfully.${NC}"
    return 0
  else
    echo -e "${RED}Failed to delete tag ${DELETE_TAG}. HTTP status: ${DELETE_STATUS}${NC}"
    return 1
  fi
}


# Function to delete a specific tag
delete_tag() {
  check_credentials
  list_tags  # Show tags first
  read -p "Enter the tag to delete (or 'cancel' to abort): " DELETE_TAG
  if [ "$DELETE_TAG" == "cancel" ]; then
    echo -e "${BLUE}Deletion aborted.${NC}"
    return
  fi

  delete_by_tag "$DELETE_TAG"
}

# Function to delete all tags
delete_all_tags() {
  check_credentials
  echo -e "${RED}Warning: This will delete ALL tags for ${REGISTRY}/${IMAGE_NAME}!${NC}"
  read -p "Are you sure? (yes/no): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo -e "${BLUE}Deletion aborted.${NC}"
    return
  fi

  CURL_OUTPUT=$(curl -s -u "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" "https://${REGISTRY}/v2/${IMAGE_NAME}/tags/list")
  TAGS=$(echo "$CURL_OUTPUT" | grep -oP '(?<="tags":\[)[^]]*' | tr -d '"' | tr ',' ' ')

  if [ -z "$TAGS" ]; then
    echo -e "${BLUE}No tags to delete.${NC}"
    return
  fi

  for TAG in $TAGS; do
    delete_by_tag "$TAG"
  done
  echo -e "${GREEN}All tags deletion attempted.${NC}"
}

# Function to run garbage collection via SSH
run_garbage_collection() {
  if [ -z "$REGISTRY_CONTAINER_NAME" ]; then
    REGISTRY_CONTAINER_NAME="docker-registry"
    echo -e "${BLUE}Using default container name: ${REGISTRY_CONTAINER_NAME}. If different, set REGISTRY_CONTAINER_NAME env var.${NC}"
  fi

  echo -e "${RED}Warning: This will run garbage collection on the remote registry via SSH.${NC}"
  echo -e "${BLUE}Ensure no image pushes/pulls are active on the remote server.${NC}"
  read -p "Continue with dry-run first? (yes/no): " CONFIRM_DRY
  if [ "$CONFIRM_DRY" != "yes" ]; then
    echo -e "${BLUE}Aborted.${NC}"
    return
  fi

  # Dry-run
  echo -e "${GREEN}Running dry-run garbage collection via SSH...${NC}"
  ssh "${REMOTE_USER}@${REMOTE_HOST}" "docker exec ${REGISTRY_CONTAINER_NAME} bin/registry garbage-collect /etc/docker/registry/config.yml --delete-untagged --dry-run"

  read -p "Dry-run complete. Proceed with actual garbage collection? (yes/no): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo -e "${BLUE}Aborted.${NC}"
    return
  fi

  # Actual run
  echo -e "${GREEN}Running actual garbage collection via SSH...${NC}"
  ssh "${REMOTE_USER}@${REMOTE_HOST}" "docker exec ${REGISTRY_CONTAINER_NAME} bin/registry garbage-collect /etc/docker/registry/config.yml --delete-untagged"

  echo -e "${GREEN}Garbage collection completed.${NC}"

  read -p "Restart the registry container to clear any cached tags? (yes/no): " CONFIRM_RESTART
  if [ "$CONFIRM_RESTART" == "yes" ]; then
    echo -e "${GREEN}Restarting registry container via SSH...${NC}"
    ssh "${REMOTE_USER}@${REMOTE_HOST}" "docker restart ${REGISTRY_CONTAINER_NAME}"
    echo -e "${GREEN}Registry restarted.${NC}"
  fi

  echo -e "${BLUE}Verify storage usage on the remote server (e.g., du -sh /path/to/registry/storage).${NC}"
  echo -e "${BLUE}Also, check if tags are cleared by listing them again.${NC}"
}

# Interactive menu
while true; do
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE} Woodpecker Server Tag Management Script${NC}"
  echo -e "${BLUE}========================================${NC}"
  echo -e "1. List tags"
  echo -e "2. Delete specific tag"
  echo -e "3. Delete all tags"
  echo -e "4. Run garbage collection on remote server via SSH"
  echo -e "5. Exit"
  read -p "Choose an option (1-5): " CHOICE

  case $CHOICE in
    1) list_tags ;;
    2) delete_tag ;;
    3) delete_all_tags ;;
    4) run_garbage_collection ;;
    5) echo -e "${BLUE}Exiting script.${NC}"; exit 0 ;;
    *) echo -e "${RED}Invalid option. Please try again.${NC}" ;;
  esac

  echo ""
done
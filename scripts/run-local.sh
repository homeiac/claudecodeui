#!/bin/bash
# Run ClaudeCodeUI locally for debugging
# Usage: ./run-local.sh [--build] [--test]
#   --build  Force rebuild image
#   --test   Use test/ topic prefix (doesn't affect prod)
set -e

cd "$(dirname "$0")/.."

# Parse args
BUILD=false
TEST_MODE=false
for arg in "$@"; do
    case $arg in
        --build) BUILD=true ;;
        --test) TEST_MODE=true ;;
    esac
done

# Get MQTT credentials from K8s secret
echo "=== Getting MQTT credentials from K8s ==="
MQTT_USER=$(KUBECONFIG=~/kubeconfig kubectl get secret mqtt-credentials -n claudecodeui -o jsonpath='{.data.username}' | base64 -d)
MQTT_PASS=$(KUBECONFIG=~/kubeconfig kubectl get secret mqtt-credentials -n claudecodeui -o jsonpath='{.data.password}' | base64 -d)
echo "   User: $MQTT_USER"

# Stop existing container if running
docker stop claudecodeui-local 2>/dev/null || true

# Build if needed
if [[ "$BUILD" == "true" ]] || [[ -z "$(docker images -q claudecodeui:local 2>/dev/null)" ]]; then
    echo ""
    echo "=== Building local image ==="
    docker build -t claudecodeui:local .
fi

# Set topic prefix for test mode
TOPIC_PREFIX=""
if [[ "$TEST_MODE" == "true" ]]; then
    TOPIC_PREFIX="test/"
    echo ""
    echo "=== TEST MODE: Using topic prefix 'test/' ==="
    echo "   Topics: test/claude/command, test/claude/home/response, etc."
fi

echo ""
echo "=== Running locally (detached) ==="
docker run --rm -d \
    -p 3001:3001 \
    --name claudecodeui-local \
    -e MQTT_ENABLED=true \
    -e MQTT_BROKER_URL=mqtt://homeassistant.maas:1883 \
    -e MQTT_USERNAME="$MQTT_USER" \
    -e MQTT_PASSWORD="$MQTT_PASS" \
    -e MQTT_COMMAND_TOPIC="${TOPIC_PREFIX}claude/command" \
    -e MQTT_RESPONSE_TOPIC="${TOPIC_PREFIX}claude/home/response" \
    -e MQTT_APPROVAL_REQUEST_TOPIC="${TOPIC_PREFIX}claude/approval-request" \
    -e MQTT_APPROVAL_RESPONSE_TOPIC="${TOPIC_PREFIX}claude/approval-response" \
    -e KUBECONFIG=/home/claude/kubeconfig \
    -v ~/.claude:/home/claude/.claude \
    -v ~/kubeconfig:/home/claude/kubeconfig:ro \
    claudecodeui:local

echo ""
echo "=== Waiting for startup ==="
sleep 5

echo ""
echo "=== Logs ==="
docker logs claudecodeui-local 2>&1

echo ""
echo "=== To follow logs: docker logs -f claudecodeui-local ==="

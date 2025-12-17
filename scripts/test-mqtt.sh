#!/bin/bash
# Test MQTT connection and Claude command/response
# Usage: ./test-mqtt.sh [--test] [--approval] [--simple]
#   --test     Use test/ topic prefix (for local testing, doesn't affect prod)
#   --approval Test approval workflow
#   --simple   Simple TTS test
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

# Load from .env if exists
if [[ -f "$ENV_FILE" ]]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
fi

# Parse args for --test flag
TOPIC_PREFIX=""
for arg in "$@"; do
    if [[ "$arg" == "--test" ]]; then
        TOPIC_PREFIX="test/"
        echo "=== TEST MODE: Using topic prefix 'test/' ==="
    fi
done

# Parse broker URL
MQTT_HOST="${MQTT_BROKER_URL#mqtt://}"
MQTT_HOST="${MQTT_HOST%:*}"
MQTT_HOST="${MQTT_HOST:-homeassistant.maas}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USERNAME}"
MQTT_PASS="${MQTT_PASSWORD}"

if [[ -z "$MQTT_USER" || -z "$MQTT_PASS" ]]; then
    echo "Usage: $0 [--test] [--approval] [--simple]"
    echo ""
    echo "Set MQTT_USERNAME and MQTT_PASSWORD in .env"
    exit 1
fi

# Topic configuration
COMMAND_TOPIC="${TOPIC_PREFIX}claude/command"
RESPONSE_TOPIC="${TOPIC_PREFIX}claude/home/response"
APPROVAL_REQUEST_TOPIC="${TOPIC_PREFIX}claude/approval-request"
APPROVAL_RESPONSE_TOPIC="${TOPIC_PREFIX}claude/approval-response"

echo "=== Testing MQTT Connection ==="
echo "Host: $MQTT_HOST"
echo "User: $MQTT_USER"
echo "Topics: ${TOPIC_PREFIX}claude/*"
echo ""

# Check if mosquitto_pub/sub are available
if ! command -v mosquitto_pub &>/dev/null; then
    echo "ERROR: mosquitto_pub not found. Install with: brew install mosquitto"
    exit 1
fi

# Test 1: Basic connectivity
echo "1. Testing publish..."
mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
    -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "${TOPIC_PREFIX}claude/test" -m "test-$(date +%s)" && echo "   OK" || { echo "   FAILED"; exit 1; }

# Test 2: Subscribe to response and send command (skip if --approval-only)
if [[ "$1" != "--approval-only" && "$2" != "--approval-only" ]]; then
echo ""
echo "2. Testing Claude command/response..."

# Configurable timeout and message count
TIMEOUT=${MQTT_TIMEOUT:-45}
MSG_COUNT=${MQTT_MSG_COUNT:-10}

# Start subscriber in background
RESPONSE_FILE=$(mktemp)
echo "   Subscribing to claude/home/response (${TIMEOUT}s timeout, ${MSG_COUNT} messages max)..."
mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" \
    -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "$RESPONSE_TOPIC" -C "$MSG_COUNT" -W "$TIMEOUT" > "$RESPONSE_FILE" 2>/dev/null &
SUB_PID=$!
sleep 1

# Send command
echo "   Sending: What is 2+2? Reply with just the number."
mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
    -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "$COMMAND_TOPIC" \
    -m '{"source":"test-script","message":"What is 2+2? Reply with just the number.","stream":false}'

# Wait for response
echo "   Waiting for response..."
wait $SUB_PID 2>/dev/null || true

# Check response
if [[ -s "$RESPONSE_FILE" ]]; then
    echo ""
    echo "=== Responses Received ==="
    # Pretty print if jq available, otherwise raw
    if command -v jq &>/dev/null; then
        cat "$RESPONSE_FILE" | while read line; do
            echo "$line" | jq -c '.type + ": " + (.content | tostring)' 2>/dev/null || echo "$line"
        done
    else
        cat "$RESPONSE_FILE"
    fi
    echo ""

    # Check for completion message
    if grep -q '"type":"complete"' "$RESPONSE_FILE"; then
        echo "=== SUCCESS: Response completed ==="
    elif grep -q '"type":"error"' "$RESPONSE_FILE"; then
        echo "=== ERROR: Check pod logs ==="
        KUBECONFIG="${KUBECONFIG:-$HOME/kubeconfig}" kubectl logs -n claudecodeui deployment/claudecodeui-blue --tail=10 2>/dev/null | grep -E "Error|error" || true
    fi
else
    echo "   No response received (timeout or error)"
    echo ""
    echo "   Checking pod logs..."
    KUBECONFIG="${KUBECONFIG:-$HOME/kubeconfig}" kubectl logs -n claudecodeui deployment/claudecodeui-blue --tail=15 2>/dev/null | grep -E "MQTT|command|Error" || echo "   Could not get logs"
fi

rm -f "$RESPONSE_FILE"
fi  # end of step 2

APPROVAL_ONLY=false
[[ "$1" == "--approval-only" || "$2" == "--approval-only" ]] && APPROVAL_ONLY=true

# Test 3: Approval workflow (if --approval or --approval-only flag)
if [[ "$1" == "--approval"* || "$2" == "--approval"* || "$3" == "--approval"* ]]; then
    echo ""
    echo "3. Testing approval workflow..."
    echo "   This will ask Claude to run kubectl which requires approval"
    echo ""

    # Subscribe to all claude topics to see the full flow
    APPROVAL_FILE=$(mktemp)
    echo "   Subscribing to claude/# (30s timeout)..."
    mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASS" \
        -t "${TOPIC_PREFIX}claude/#" -v -W 30 > "$APPROVAL_FILE" 2>/dev/null &
    SUB_PID=$!
    sleep 1

    # Send command that requires approval (rm, kubectl delete, etc. - not auto-approved)
    echo "   Sending: delete /tmp/test-approval-file.txt"
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASS" \
        -t "$COMMAND_TOPIC" \
        -m '{"source":"test-script","message":"delete the file /tmp/test-approval-file.txt using rm command","stream":true}'

    # Monitor for approval-request and auto-approve (unit test - no HA dependency)
    echo "   Monitoring for approval-request (will auto-approve)..."

    # Poll for approval request for up to 20 seconds
    for i in {1..20}; do
        if grep -q "approval-request" "$APPROVAL_FILE" 2>/dev/null; then
            echo ""
            echo "=== Approval request received! ==="
            grep "approval-request" "$APPROVAL_FILE" | tail -1 | cut -d' ' -f2- | jq '.'

            # Extract requestId and auto-approve
            REQUEST_ID=$(grep "approval-request" "$APPROVAL_FILE" | tail -1 | cut -d' ' -f2- | jq -r '.requestId')
            COMMAND=$(grep "approval-request" "$APPROVAL_FILE" | tail -1 | cut -d' ' -f2- | jq -r '.command // .tool')

            if [[ -n "$REQUEST_ID" && "$REQUEST_ID" != "null" ]]; then
                echo ""
                echo "   Command: $COMMAND"
                echo "   RequestId: $REQUEST_ID"
                echo "   Auto-approving..."

                mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
                    -u "$MQTT_USER" -P "$MQTT_PASS" \
                    -t "$APPROVAL_RESPONSE_TOPIC" \
                    -m "{\"requestId\":\"$REQUEST_ID\",\"approved\":true}"
                echo "   ✓ Sent approval to claude/approval-response"
                break
            fi
        fi
        sleep 1
    done

    if ! grep -q "approval-request" "$APPROVAL_FILE" 2>/dev/null; then
        echo ""
        echo "   ✗ No approval-request seen after 20s"
        echo "   The command may have been auto-approved or didn't need approval"
    fi

    # Wait for completion
    echo ""
    echo "   Waiting for command completion..."
    sleep 5

    # Wait for subscriber
    wait $SUB_PID 2>/dev/null || true

    echo ""
    echo "=== Full message log ==="
    cat "$APPROVAL_FILE"
    rm -f "$APPROVAL_FILE"
fi

# Test 4: Simple TTS test (if --simple flag)
if [[ "$1" == "--simple" || "$2" == "--simple" || "$3" == "--simple" ]]; then
    echo ""
    echo "4. Simple TTS test (streaming)..."
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASS" \
        -t "$COMMAND_TOPIC" \
        -m '{"source":"test-script","message":"What is 2+2? Reply with just the number.","stream":true}'
    echo "   Sent with stream:true - listen for TTS on Voice PE"
    sleep 5
fi

echo ""
echo "=== Test Complete ==="

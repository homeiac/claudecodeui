#!/bin/bash
# Test full HA approval flow (Voice PE simulation)
# This test does NOT auto-approve - it relies on HA automation to respond
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

# Load from .env
if [[ -f "$ENV_FILE" ]]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
fi

MQTT_HOST="${MQTT_BROKER_URL#mqtt://}"
MQTT_HOST="${MQTT_HOST%:*}"
MQTT_HOST="${MQTT_HOST:-homeassistant.maas}"
MQTT_PORT="${MQTT_PORT:-1883}"
MQTT_USER="${MQTT_USERNAME}"
MQTT_PASS="${MQTT_PASSWORD}"

[[ -z "$MQTT_USER" || -z "$MQTT_PASS" ]] && { echo "ERROR: MQTT credentials not found in .env"; exit 1; }

echo "=== HA Approval Flow Test ==="
echo "Host: $MQTT_HOST"
echo ""
echo "This test sends a command requiring approval and waits for HA to respond."
echo "You must approve via Voice PE dial (CW) or button."
echo ""

# Create temp file for MQTT messages
MQTT_LOG=$(mktemp)

# Subscribe to all claude topics in background
echo "1. Subscribing to claude/# ..."
mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" \
    -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "claude/#" -v -W 60 > "$MQTT_LOG" 2>/dev/null &
SUB_PID=$!
sleep 1

# Send command that requires approval
echo "2. Sending command: rm /tmp/test-ha-approval.txt"
mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
    -u "$MQTT_USER" -P "$MQTT_PASS" \
    -t "claude/command" \
    -m '{"source":"ha-test","message":"delete the file /tmp/test-ha-approval.txt","stream":true}'

# Wait for approval-request
echo "3. Waiting for approval-request..."
for i in {1..30}; do
    if grep -q "approval-request" "$MQTT_LOG" 2>/dev/null; then
        echo ""
        echo "=== Approval Request ==="
        grep "approval-request" "$MQTT_LOG" | cut -d' ' -f2- | jq '.'

        REQUEST_ID=$(grep "approval-request" "$MQTT_LOG" | cut -d' ' -f2- | jq -r '.requestId')
        echo ""
        echo "RequestId: $REQUEST_ID"
        echo ""
        echo ">>> NOW: Rotate Voice PE dial CLOCKWISE to approve <<<"
        echo ""
        break
    fi
    sleep 1
done

if ! grep -q "approval-request" "$MQTT_LOG" 2>/dev/null; then
    echo "ERROR: No approval-request received"
    kill $SUB_PID 2>/dev/null || true
    rm -f "$MQTT_LOG"
    exit 1
fi

# Wait for approval-response from HA
echo "4. Waiting for approval-response from HA (rotate dial CW)..."
for i in {1..30}; do
    if grep -q "approval-response" "$MQTT_LOG" 2>/dev/null; then
        echo ""
        echo "=== Approval Response (from HA) ==="
        grep "approval-response" "$MQTT_LOG" | cut -d' ' -f2- | jq '.'

        RESPONSE_ID=$(grep "approval-response" "$MQTT_LOG" | cut -d' ' -f2- | jq -r '.requestId')
        APPROVED=$(grep "approval-response" "$MQTT_LOG" | cut -d' ' -f2- | jq -r '.approved')

        echo ""
        if [[ "$RESPONSE_ID" == "$REQUEST_ID" ]]; then
            echo "✓ RequestId matches!"
        else
            echo "✗ RequestId MISMATCH: expected $REQUEST_ID, got $RESPONSE_ID"
        fi

        if [[ "$APPROVED" == "true" ]]; then
            echo "✓ Approved!"
        else
            echo "✗ Rejected"
        fi
        break
    fi
    sleep 1
done

if ! grep -q "approval-response" "$MQTT_LOG" 2>/dev/null; then
    echo ""
    echo "ERROR: No approval-response received (did you rotate the dial?)"
fi

# Wait for completion
echo ""
echo "5. Waiting for command completion..."
sleep 5

# Show result
echo ""
echo "=== Result ==="
if grep -q '"type":"result"' "$MQTT_LOG" 2>/dev/null; then
    grep '"type":"result"' "$MQTT_LOG" | tail -1 | cut -d' ' -f2- | jq -r '.content.data.result // .text // "Command completed"'
else
    echo "(No result message found)"
fi

# Cleanup
kill $SUB_PID 2>/dev/null || true
rm -f "$MQTT_LOG"

echo ""
echo "=== Test Complete ==="

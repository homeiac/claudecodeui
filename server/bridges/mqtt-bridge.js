/**
 * MQTT Bridge for Claude Code UI
 *
 * Enables bidirectional communication between MQTT-connected devices
 * (e.g., Home Assistant, Cardputer, Voice PE) and the Claude SDK.
 *
 * Topics:
 * - claude/command (IN) - Commands from devices
 * - claude/home/response (OUT) - Responses to devices
 * - claude/approval-request (OUT) - Permission requests
 * - claude/approval-response (IN) - Permission responses from devices
 */

import mqtt from 'mqtt';
import { approvalQueue } from './approval-queue.js';
import { queryClaudeSDK } from '../claude-sdk.js';

// Configuration from environment
const CONFIG = {
  enabled: process.env.MQTT_ENABLED === 'true',
  brokerUrl: process.env.MQTT_BROKER_URL || 'mqtt://localhost:1883',
  commandTopic: process.env.MQTT_COMMAND_TOPIC || 'claude/command',
  responseTopic: process.env.MQTT_RESPONSE_TOPIC || 'claude/home/response',
  approvalRequestTopic: process.env.MQTT_APPROVAL_REQUEST_TOPIC || 'claude/approval-request',
  approvalResponseTopic: process.env.MQTT_APPROVAL_RESPONSE_TOPIC || 'claude/approval-response',
  clientId: process.env.MQTT_CLIENT_ID || `claudecodeui-${Date.now()}`,
  username: process.env.MQTT_USERNAME || undefined,
  password: process.env.MQTT_PASSWORD || undefined,
  approvalTimeout: parseInt(process.env.MQTT_APPROVAL_TIMEOUT || '60000', 10)
};

let mqttClient = null;

/**
 * MQTTResponseWriter - Adapts SDK WebSocket-like interface to MQTT publishing
 */
class MQTTResponseWriter {
  constructor(client, responseTopic, sessionId, sourceDevice, streaming = true) {
    this.client = client;
    this.topic = responseTopic;
    this.sessionId = sessionId;
    this.sourceDevice = sourceDevice;
    this.streaming = streaming;
    this.startTime = Date.now();
    this.messageBuffer = [];
  }

  send(data) {
    const message = typeof data === 'string' ? JSON.parse(data) : data;

    if (this.streaming) {
      // Check if this is a result message with answer text
      const innerData = message?.data;
      if (innerData?.type === 'result' && innerData?.result) {
        // Publish simplified answer message for voice assistants
        this.client.publish(this.topic, JSON.stringify({
          type: 'answer',
          text: innerData.result,
          session_id: this.sessionId,
          source_device: this.sourceDevice,
          timestamp: Date.now()
        }));
      }
      // Also publish full chunk for debugging/other consumers
      this.client.publish(this.topic, JSON.stringify({
        type: 'chunk',
        content: message,
        session_id: this.sessionId,
        source_device: this.sourceDevice,
        timestamp: Date.now()
      }));
    } else {
      // Buffer for final response
      this.messageBuffer.push(message);
    }
  }

  end() {
    const durationMs = Date.now() - this.startTime;

    if (!this.streaming) {
      // Publish aggregated response
      this.client.publish(this.topic, JSON.stringify({
        type: 'complete',
        content: this.messageBuffer,
        session_id: this.sessionId,
        source_device: this.sourceDevice,
        duration_ms: durationMs,
        timestamp: Date.now()
      }));
    } else {
      // Publish completion marker
      this.client.publish(this.topic, JSON.stringify({
        type: 'complete',
        session_id: this.sessionId,
        source_device: this.sourceDevice,
        duration_ms: durationMs,
        timestamp: Date.now()
      }));
    }
  }

  setSessionId(id) {
    this.sessionId = id;
  }
}

/**
 * Creates a canUseTool callback that publishes approval requests to MQTT
 */
function createMqttCanUseTool(sessionId, sourceDevice) {
  return async (toolName, input) => {
    const requestId = approvalQueue.generateRequestId();
    const startTime = Date.now();

    console.log(`[MQTT Approval] >>> REQUEST ${requestId}`);
    console.log(`[MQTT Approval]     Tool: ${toolName}`);
    console.log(`[MQTT Approval]     Command: ${input.command || 'N/A'}`);
    console.log(`[MQTT Approval]     Session: ${sessionId}, Device: ${sourceDevice}`);
    console.log(`[MQTT Approval]     Timeout: ${CONFIG.approvalTimeout}ms`);
    console.log(`[MQTT Approval]     Publishing to: ${CONFIG.approvalRequestTopic}`);

    // Publish approval request to MQTT
    mqttClient.publish(CONFIG.approvalRequestTopic, JSON.stringify({
      requestId,
      toolName,
      input: {
        command: input.command,
        description: input.description
      },
      sessionId,
      sourceDevice,
      timestamp: Date.now()
    }));

    console.log(`[MQTT Approval]     Published, waiting for response on: ${CONFIG.approvalResponseTopic}`);

    try {
      // Wait for response via approval queue
      const response = await approvalQueue.waitForResponse(requestId, CONFIG.approvalTimeout);
      const elapsed = Date.now() - startTime;

      console.log(`[MQTT Approval] <<< RESPONSE ${requestId} (${elapsed}ms)`);
      console.log(`[MQTT Approval]     Approved: ${response.approved}`);
      console.log(`[MQTT Approval]     Reason: ${response.reason || 'N/A'}`);

      if (response.approved) {
        return { behavior: 'allow', updatedInput: input };
      } else {
        return { behavior: 'deny', message: response.reason || 'Denied by user' };
      }
    } catch (error) {
      const elapsed = Date.now() - startTime;
      console.error(`[MQTT Approval] !!! TIMEOUT/ERROR ${requestId} (${elapsed}ms)`);
      console.error(`[MQTT Approval]     Error: ${error.message}`);
      console.error(`[MQTT Approval]     Pending requests: ${approvalQueue.getPendingCount()}`);
      return { behavior: 'deny', message: `Approval timeout: ${error.message}` };
    }
  };
}

/**
 * Publish an error to the response topic
 */
function publishError(sessionId, sourceDevice, error) {
  if (!mqttClient) return;

  mqttClient.publish(CONFIG.responseTopic, JSON.stringify({
    type: 'error',
    error: error.message || String(error),
    session_id: sessionId,
    source_device: sourceDevice,
    timestamp: Date.now()
  }));
}

// Track active command to prevent race conditions
let activeCommand = null;

/**
 * Handle incoming command from MQTT
 */
async function handleCommand(payload) {
  const sessionId = payload.session_id || approvalQueue.generateRequestId();
  const sourceDevice = payload.source || 'unknown';

  console.log(`[MQTT Bridge] Received command from ${sourceDevice}:`, payload.message?.substring(0, 100));

  // Cancel any previous pending approval requests to prevent race conditions
  if (approvalQueue.getPendingCount() > 0) {
    console.log(`[MQTT Bridge] Cancelling ${approvalQueue.getPendingCount()} pending approval requests`);
    approvalQueue.cancelAll('New command received');
  }

  // Track this command as active
  if (activeCommand) {
    console.log(`[MQTT Bridge] Previous command still running, will proceed anyway`);
  }
  activeCommand = { sessionId, sourceDevice, startTime: Date.now() };

  try {
    // Validate required fields
    if (!payload.message) {
      throw new Error('Missing required field: message');
    }

    // Verify Claude CLI is authenticated (checks ~/.claude/.credentials.json)
    // The SDK will use these credentials directly
    const credentialsPath = process.env.HOME + '/.claude/.credentials.json';
    try {
      const fs = await import('fs/promises');
      await fs.access(credentialsPath);
    } catch {
      throw new Error('Claude CLI not authenticated. Run "claude" to login first.');
    }

    // Create MQTT response writer
    const writer = new MQTTResponseWriter(
      mqttClient,
      CONFIG.responseTopic,
      sessionId,
      sourceDevice,
      payload.stream !== false // Default to streaming
    );

    // Build SDK options
    const sdkOptions = {
      cwd: payload.project || process.cwd(),
      sessionId: payload.session_id || null,
      permissionMode: 'default', // Use default mode so canUseTool gets called
      canUseTool: createMqttCanUseTool(sessionId, sourceDevice)
    };

    // Execute query
    await queryClaudeSDK(payload.message, sdkOptions, writer);

    // Signal completion
    writer.end();
    activeCommand = null;

  } catch (error) {
    console.error('[MQTT Bridge] Error handling command:', error);
    publishError(sessionId, sourceDevice, error);
    activeCommand = null;
  }
}

/**
 * Handle incoming approval response from MQTT
 */
function handleApprovalResponse(payload) {
  console.log(`[MQTT Approval] === INCOMING RESPONSE ===`);
  console.log(`[MQTT Approval]     Full payload:`, JSON.stringify(payload));
  console.log(`[MQTT Approval]     requestId: ${payload.requestId || 'MISSING!'}`);
  console.log(`[MQTT Approval]     approved: ${payload.approved}`);
  console.log(`[MQTT Approval]     reason: ${payload.reason || 'N/A'}`);
  console.log(`[MQTT Approval]     Pending queue size: ${approvalQueue.getPendingCount()}`);

  if (!payload.requestId) {
    console.error('[MQTT Approval] !!! Response REJECTED - missing requestId');
    console.error('[MQTT Approval]     Hint: HA automation must include requestId from input_text.claude_approval_request_id');
    return;
  }

  const matched = approvalQueue.handleResponse(
    payload.requestId,
    payload.approved === true,
    payload.reason
  );

  if (!matched) {
    console.error(`[MQTT Approval] !!! Response ORPHANED - no pending request for ${payload.requestId}`);
    console.error(`[MQTT Approval]     Possible causes: timeout already occurred, or requestId mismatch`);
  } else {
    console.log(`[MQTT Approval] ✓ Response MATCHED and delivered for ${payload.requestId}`);
  }
}

/**
 * Initialize and connect MQTT bridge
 */
export function initMqttBridge() {
  if (!CONFIG.enabled) {
    console.log('[MQTT Bridge] Disabled via MQTT_ENABLED=false');
    return null;
  }

  console.log(`[MQTT Bridge] Connecting to ${CONFIG.brokerUrl}`);

  mqttClient = mqtt.connect(CONFIG.brokerUrl, {
    clientId: CONFIG.clientId,
    username: CONFIG.username,
    password: CONFIG.password,
    reconnectPeriod: 5000,
    clean: true
  });

  mqttClient.on('connect', () => {
    console.log(`[MQTT Bridge] Connected to ${CONFIG.brokerUrl}`);

    // Subscribe to command topic
    mqttClient.subscribe(CONFIG.commandTopic, (err) => {
      if (err) {
        console.error('[MQTT Bridge] Subscribe error (command):', err);
      } else {
        console.log(`[MQTT Bridge] Subscribed to ${CONFIG.commandTopic}`);
      }
    });

    // Subscribe to approval response topic
    mqttClient.subscribe(CONFIG.approvalResponseTopic, (err) => {
      if (err) {
        console.error('[MQTT Bridge] Subscribe error (approval):', err);
      } else {
        console.log(`[MQTT Bridge] Subscribed to ${CONFIG.approvalResponseTopic}`);
      }
    });

    // Publish online status
    mqttClient.publish('claude/home/status', JSON.stringify({
      server: 'home',
      online: true,
      timestamp: Date.now()
    }), { retain: true });
  });

  mqttClient.on('message', (topic, message) => {
    try {
      const payload = JSON.parse(message.toString());

      if (topic === CONFIG.commandTopic) {
        handleCommand(payload);
      } else if (topic === CONFIG.approvalResponseTopic) {
        handleApprovalResponse(payload);
      } else {
        console.log(`[MQTT Bridge] Unknown topic: ${topic}`);
      }
    } catch (error) {
      console.error('[MQTT Bridge] Error processing message:', error);
    }
  });

  mqttClient.on('error', (error) => {
    console.error('[MQTT Bridge] Connection error:', error);
  });

  mqttClient.on('close', () => {
    console.log('[MQTT Bridge] Connection closed');
    // Publish offline status (will be retained)
    if (mqttClient && mqttClient.connected) {
      mqttClient.publish('claude/home/status', JSON.stringify({
        server: 'home',
        online: false,
        timestamp: Date.now()
      }), { retain: true });
    }
  });

  mqttClient.on('reconnect', () => {
    console.log('[MQTT Bridge] Reconnecting...');
  });

  return mqttClient;
}

/**
 * Gracefully shutdown MQTT bridge
 */
export function shutdownMqttBridge() {
  if (mqttClient) {
    console.log('[MQTT Bridge] Shutting down...');

    // Cancel all pending approvals
    approvalQueue.cancelAll('MQTT bridge shutdown');

    // Publish offline status
    mqttClient.publish('claude/home/status', JSON.stringify({
      server: 'home',
      online: false,
      timestamp: Date.now()
    }), { retain: true });

    mqttClient.end(true);
    mqttClient = null;
  }
}

export { CONFIG as mqttConfig, mqttClient };

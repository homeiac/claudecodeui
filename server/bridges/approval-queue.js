/**
 * Approval Queue for MQTT-based permission requests
 *
 * Correlates approval requests with their responses using requestId.
 * Handles timeouts for unanswered requests.
 */

import crypto from 'crypto';

class ApprovalQueue {
  constructor() {
    // Map of requestId -> { resolve, reject, timeout }
    this.pending = new Map();
    this.defaultTimeout = 60000; // 60 seconds
  }

  /**
   * Generate a unique request ID
   */
  generateRequestId() {
    return crypto.randomUUID();
  }

  /**
   * Wait for an approval response
   * @param {string} requestId - The unique request identifier
   * @param {number} timeoutMs - Timeout in milliseconds (default: 60s)
   * @returns {Promise<{approved: boolean, reason?: string}>}
   */
  waitForResponse(requestId, timeoutMs = this.defaultTimeout) {
    return new Promise((resolve, reject) => {
      // Set up timeout
      const timeout = setTimeout(() => {
        this.pending.delete(requestId);
        reject(new Error(`Approval timeout after ${timeoutMs}ms`));
      }, timeoutMs);

      // Store the resolver
      this.pending.set(requestId, {
        resolve: (response) => {
          clearTimeout(timeout);
          this.pending.delete(requestId);
          resolve(response);
        },
        reject: (error) => {
          clearTimeout(timeout);
          this.pending.delete(requestId);
          reject(error);
        },
        timeout
      });
    });
  }

  /**
   * Handle an incoming approval response
   * @param {string} requestId - The request ID being responded to
   * @param {boolean} approved - Whether the request was approved
   * @param {string} reason - Optional reason for denial
   * @returns {boolean} - Whether the response was matched to a pending request
   */
  handleResponse(requestId, approved, reason = null) {
    const pending = this.pending.get(requestId);
    if (!pending) {
      console.warn(`[ApprovalQueue] No pending request found for ${requestId}`);
      return false;
    }

    pending.resolve({
      approved,
      reason: reason || (approved ? null : 'Denied by user')
    });
    return true;
  }

  /**
   * Cancel a pending approval request
   * @param {string} requestId - The request ID to cancel
   * @param {string} reason - Reason for cancellation
   */
  cancelRequest(requestId, reason = 'Request cancelled') {
    const pending = this.pending.get(requestId);
    if (pending) {
      pending.reject(new Error(reason));
    }
  }

  /**
   * Get count of pending requests
   */
  getPendingCount() {
    return this.pending.size;
  }

  /**
   * Cancel all pending requests (for cleanup)
   */
  cancelAll(reason = 'Queue shutdown') {
    for (const [requestId, pending] of this.pending) {
      pending.reject(new Error(reason));
    }
    this.pending.clear();
  }
}

// Singleton instance
const approvalQueue = new ApprovalQueue();

export { ApprovalQueue, approvalQueue };
export default approvalQueue;

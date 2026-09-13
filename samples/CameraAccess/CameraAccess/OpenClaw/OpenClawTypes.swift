//
//  OpenClawTypes.swift
//  CameraAccess
//
//  Supporting types for the ported OpenClaw client.
//
//  OpenClawService/OpenClawProtocol/OpenClawDeviceIdentity were ported from OpenVision, where
//  these two enums live in `Services/AIBackend/AIBackendProtocol.swift` alongside a wider
//  multi-backend abstraction. VisionClaw has no such abstraction and needs only these two, so
//  they are reproduced here rather than dragging the protocol layer across.
//
//  Keep them in sync with OpenVision if that client is updated.
//

import Foundation

/// Connection lifecycle of the OpenClaw WebSocket link.
enum AIConnectionState: Equatable, CustomStringConvertible {
  /// Not connected
  case disconnected

  /// Connection attempt in progress
  case connecting

  /// Fully connected and operational
  case connected

  /// Auto-reconnecting after unexpected drop
  case reconnecting(attempt: Int)

  /// App backgrounded, connection intentionally paused
  case suspended

  /// Connection failed after max retries
  case failed(String)

  var isUsable: Bool {
    if case .connected = self { return true }
    return false
  }

  var isAttempting: Bool {
    switch self {
    case .connecting, .reconnecting: return true
    default: return false
    }
  }

  var description: String {
    switch self {
    case .disconnected: return "Disconnected"
    case .connecting: return "Connecting..."
    case .connected: return "Connected"
    case .reconnecting(let n): return "Reconnecting (attempt \(n))..."
    case .suspended: return "Suspended"
    case .failed(let msg): return "Failed: \(msg)"
    }
  }

  var statusColor: String {
    switch self {
    case .disconnected: return "gray"
    case .connecting, .reconnecting: return "orange"
    case .connected: return "green"
    case .suspended: return "yellow"
    case .failed: return "red"
    }
  }
}

/// Errors surfaced by the OpenClaw client.
enum AIBackendError: LocalizedError {
  case notConfigured
  case notConnected
  case connectionFailed
  case connectionTimeout
  case invalidResponse
  case requestFailed(String)

  var errorDescription: String? {
    switch self {
    case .notConfigured: return "AI backend not configured"
    case .notConnected: return "Not connected to AI backend"
    case .connectionFailed: return "Failed to connect to AI backend"
    case .connectionTimeout: return "Connection timed out"
    case .invalidResponse: return "Invalid response from AI backend"
    case .requestFailed(let msg): return "Request failed: \(msg)"
    }
  }
}

/// Tuning values for the OpenClaw link, ported from OpenVision's `Config/Constants.swift`.
/// Only the `OpenClaw` group is reproduced — the rest of that file is OpenVision-specific.
enum Constants {
  enum OpenClaw {
    /// Maximum reconnection attempts before giving up
    static let maxReconnectAttempts = 12

    /// Initial reconnection delay in seconds
    static let initialReconnectDelay: TimeInterval = 1.0

    /// Maximum reconnection delay in seconds
    static let maxReconnectDelay: TimeInterval = 30.0

    /// Heartbeat ping interval in seconds
    static let heartbeatInterval: TimeInterval = 20.0

    /// Pong timeout in seconds
    static let pongTimeout: TimeInterval = 10.0
  }
}

// NOTE: `String.nilIfEmpty` is NOT defined here — OpenClawService.swift already carries its own
// fileprivate copy. Adding a second one is an "invalid redeclaration" build error.

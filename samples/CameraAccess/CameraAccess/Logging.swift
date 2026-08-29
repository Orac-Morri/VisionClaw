import Foundation
import os

/// One subsystem for the whole app, one category per area.
///
/// NSLog wrote to a channel that the device syslog relay does not carry, so
/// nothing the app logged was readable from a Mac -- only the system
/// frameworks running inside the process showed up. Logging through `Logger`
/// with an explicit subsystem makes the app's own output visible to
/// `log collect`/`log show` and Console.app, filterable with:
///
///     subsystem == "com.mpagnucco.VisionClaw"
///     subsystem == "com.mpagnucco.VisionClaw" AND category == "Stream"
///
/// Note on privacy: os_log redacts interpolated values as `<private>` unless
/// marked `.public`. Everything logged here is device state and error text,
/// never user content, so call sites mark values public -- otherwise the logs
/// would be less useful than the NSLog they replace.
enum Log {
  private static let subsystem = Bundle.main.bundleIdentifier ?? "com.mpagnucco.VisionClaw"

  /// App lifecycle and SDK availability.
  static let app = Logger(subsystem: subsystem, category: "App")
  /// Glasses session, camera and stream (the DAT path).
  static let stream = Logger(subsystem: subsystem, category: "Stream")
  /// LiveKit room, camera preview and data messages.
  static let liveKit = Logger(subsystem: subsystem, category: "LiveKit")
  /// VideoToolbox decode of compressed glasses frames.
  static let videoDecoder = Logger(subsystem: subsystem, category: "VideoDecoder")
}

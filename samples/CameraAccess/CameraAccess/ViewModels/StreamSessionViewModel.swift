/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Core view model demonstrating video streaming from Meta wearable devices using the DAT SDK.
// This class showcases the key streaming patterns: device selection, session management,
// video frame handling, photo capture, and error handling.
//

import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import MWDATCamera
import MWDATCore
import SwiftUI
import VideoToolbox

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

enum StreamingMode {
  case glasses
  case iPhone
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false
  @Published var streamingMode: StreamingMode = .glasses
  @Published var selectedResolution: StreamingResolution = .high

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  var resolutionLabel: String {
    switch selectedResolution {
    case .low: return "360x640"
    case .medium: return "504x896"
    case .high: return "720x1280"
    @unknown default: return "Unknown"
    }
  }

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  // DAT 0.9.0 splits the old single StreamSession into an explicit two-step
  // lifecycle: a `DeviceSession` owns the connection to the glasses, and a
  // `Camera` added to that session owns the stream. Both are nil when the
  // Wearables SDK is unavailable (simulator, or a build without glasses); the
  // iPhone camera path never touches them.
  private var deviceSession: DeviceSession?
  private var camera: MWDATCamera.Camera?
  // Listener tokens are used to manage DAT SDK event subscriptions
  private var sessionStateListenerToken: AnyListenerToken?
  private var sessionErrorListenerToken: AnyListenerToken?
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface?
  private let deviceSelector: AutoDeviceSelector?
  private var deviceMonitorTask: Task<Void, Never>?
  // CPU-based CIContext for rendering decoded pixel buffers in background
  private let cpuCIContext = CIContext(options: [.useSoftwareRenderer: true])
  // VideoDecoder for decompressing HEVC/H.264 frames in background
  private let videoDecoder = VideoDecoder()
  private var backgroundFrameCount = 0
  private var bgDiagLogged = false

  init(wearables: WearablesInterface?) {
    self.wearables = wearables

    if let wearables {
      // Let the SDK auto-select from available devices
      let selector = AutoDeviceSelector(wearables: wearables)
      self.deviceSelector = selector
      // The session is no longer created here: under 0.9.0 a DeviceSession is
      // a live connection, so it is created and started on demand in
      // startSession() rather than held idle from init.

      // Monitor device availability
      deviceMonitorTask = Task { @MainActor in
        for await device in selector.activeDeviceStream() {
          self.hasActiveDevice = device != nil
        }
      }
    } else {
      self.deviceSelector = nil
    }

    setupVideoDecoder()
  }

  /// Bridge to the LiveKit call: every decoded glasses frame is also handed
  /// here, so the room publishes exactly what the glasses see.
  var onDecodedFrame: ((CVPixelBuffer) -> Void)?

  private func setupVideoDecoder() {
    videoDecoder.setFrameCallback { [weak self] decodedFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let pixelBuffer = decodedFrame.pixelBuffer
        self.onDecodedFrame?(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
          let image = UIImage(cgImage: cgImage)
          if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
            NSLog("[Stream] Background frame #%d decoded and forwarded (%dx%d)",
                  self.backgroundFrameCount, width, height)
          }
        }
      }
    }
  }

  /// Recreate the StreamSession with the current selectedResolution.
  /// Only call when not actively streaming.
  func updateResolution(_ resolution: StreamingResolution) {
    guard !isStreaming else { return }
    selectedResolution = resolution
    // Applied the next time the camera is added: StreamConfiguration is fixed
    // at addCamera() time, so a live stream cannot change resolution in place.
    NSLog("[Stream] Resolution changed to %@", resolutionLabel)
  }

  /// 720x1280 rather than 360x640. At the low tier, printed text is a few
  /// pixels tall before JPEG compression halves it again -- the model could
  /// read a receipt's header and total but nothing smaller.
  private var streamConfiguration: StreamConfiguration {
    StreamConfiguration(
      videoCodec: VideoCodec.raw,
      resolution: selectedResolution,
      frameRate: 24)
  }

  private func attachListeners(to stream: MWDATCamera.Stream) {
    // Subscribe to stream state changes using the DAT SDK listener pattern
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        self?.updateStatusFromState(state)
      }
    }

    // Subscribe to video frames from the device camera
    // This callback fires whether the app is in the foreground or background,
    // enabling continuous streaming even when the screen is locked.
    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }

        let isInBackground = UIApplication.shared.applicationState == .background

        if !isInBackground {
          self.backgroundFrameCount = 0
          self.bgDiagLogged = false
          if let image = videoFrame.makeUIImage() {
            self.currentVideoFrame = image
            if !self.hasReceivedFirstFrame {
              self.hasReceivedFirstFrame = true
            }
          }
        } else {
          // In background: makeUIImage() uses VideoToolbox GPU rendering which iOS suspends.
          // Instead, use our VideoDecoder (VTDecompressionSession) to decode compressed
          // frames into pixel buffers, then convert via CPU CIContext.
          self.backgroundFrameCount += 1

          let sampleBuffer = videoFrame.sampleBuffer
          let hasCompressedData = CMSampleBufferGetDataBuffer(sampleBuffer) != nil

          if hasCompressedData {
            // Compressed frame (HEVC/H.264) - decode via VTDecompressionSession
            do {
              try self.videoDecoder.decode(sampleBuffer)
            } catch {
              if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
                NSLog("[Stream] Background frame #%d decode error: %@",
                      self.backgroundFrameCount, String(describing: error))
              }
            }
          } else if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            self.onDecodedFrame?(pixelBuffer)
            // Raw pixel buffer - convert directly via CPU CIContext
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
              let image = UIImage(cgImage: cgImage)
            }
            self.videoDecoder.invalidateSession()
          }
        }
      }
    }

    // Subscribe to streaming errors
    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // One voice: glasses-state conditions render as placeholder text on
        // the call screen, never as alert dialogs. Sleeping/absent glasses are
        // a plain wait; everything else maps to a typed issue.
        switch error {
        case .deviceNotConnected, .deviceNotFound:
          self.glassesIssue = nil
        case .hingesClosed:
          self.glassesIssue = .hingesClosed
        case .permissionDenied:
          self.glassesIssue = .permissionNeeded
        default:
          self.glassesIssue = .reconnecting
        }
      }
    }

    updateStatusFromState(stream.state)

    // Subscribe to photo capture events
    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self else { return }
        guard let uiImage = UIImage(data: photoData.data) else { return }
        self.capturedPhoto = uiImage
        self.showPhotoPreview = true
      }
    }
  }

  /// Glasses-state conditions the call screen's placeholder can name --
  /// the app's own voice, replacing the sample's alert dialogs.
  enum GlassesIssue: Equatable {
    case sdkUnavailable
    case permissionNeeded
    case hingesClosed
    case reconnecting
  }

  @Published var glassesIssue: GlassesIssue?

  func handleStartStreaming() async {
    glassesIssue = nil
    guard let wearables else {
      glassesIssue = .sdkUnavailable
      return
    }
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      glassesIssue = .permissionNeeded
    } catch {
      // Sleeping or out-of-range glasses are a wait state, not an error.
      let text = String(describing: error).lowercased()
      if text.contains("powered off") || text.contains("disconnected") || text.contains("no device") {
        NSLog("[Stream] glasses unavailable, waiting: %@", String(describing: error))
        glassesIssue = nil
      } else {
        glassesIssue = .reconnecting
      }
    }
  }

  /// Opens the connection to the glasses. The camera is added only once the
  /// session reports `.started` -- under 0.9.0 `addCamera` requires a started
  /// session -- so the session state observer, not this method, begins the
  /// stream. Callers keep the single-call shape they had under 0.4.0.
  func startSession() async {
    guard let wearables, let deviceSelector else {
      glassesIssue = .sdkUnavailable
      return
    }
    guard deviceSession == nil else {
      // Session already up: if it is started but the camera was torn down,
      // bring the stream back without re-creating the connection.
      if deviceSession?.state == .started, camera == nil { beginStream() }
      return
    }
    do throws(DeviceSessionError) {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session
      // Subscribe before start() so no initial transition is missed.
      observeSession(session)
      streamingStatus = .waiting
      try session.start()
    } catch {
      NSLog("[Stream] session start failed: %@", String(describing: error))
      glassesIssue = .reconnecting
      cleanupSession()
    }
  }

  private func observeSession(_ session: DeviceSession) {
    sessionStateListenerToken = session.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self else { return }
        switch state {
        case .started:
          // The stream is added here rather than in startSession() because
          // addCamera() is only valid once the session has actually connected.
          self.beginStream()
        case .stopped:
          self.streamingStatus = .stopped
          self.currentVideoFrame = nil
          self.cleanupSession()
        case .idle, .starting, .paused, .stopping:
          break
        @unknown default:
          break
        }
      }
    }
    sessionErrorListenerToken = session.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        NSLog("[Stream] session error: %@", String(describing: error))
        // Same voice as stream errors: a wait, not an alert.
        self.glassesIssue = .reconnecting
      }
    }
  }

  /// Adds the camera to a started session and starts its stream.
  private func beginStream() {
    guard let session = deviceSession, session.state == .started, camera == nil else { return }
    do {
      guard let newCamera = try session.addCamera(config: streamConfiguration) else {
        glassesIssue = .reconnecting
        return
      }
      camera = newCamera
      // Subscribe before start() so no initial transition is missed.
      attachListeners(to: newCamera.stream)
      newCamera.stream.start()
    } catch {
      NSLog("[Stream] addCamera failed: %@", String(describing: error))
      camera = nil
      glassesIssue = .reconnecting
    }
  }

  /// Drops the session and its observers so the next startSession() builds a
  /// fresh one.
  private func cleanupSession() {
    camera = nil
    deviceSession = nil
    sessionStateListenerToken = nil
    sessionErrorListenerToken = nil
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  /// Stopping the camera cascades to its stream; stopping the session is
  /// terminal and drives teardown through the state observer.
  func stopSession() async {
    camera?.stop()
    camera = nil
    deviceSession?.stop()
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func capturePhoto() {
    camera?.stream.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  private func updateStatusFromState(_ state: StreamState) {
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = .stopped
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
      glassesIssue = nil
    }
  }

  /// Currently unused -- the error publisher maps to `glassesIssue` instead --
  /// but kept as the user-facing wording for stream errors.
  private func formatStreamingError(_ error: StreamError) -> String {
    switch error {
    case .internalError:
      return "An internal error occurred. Please try again."
    case .deviceNotFound:
      return "Device not found. Please ensure your device is connected."
    case .deviceNotConnected:
      return "Device not connected. Please check your connection and try again."
    case .timeout:
      return "The operation timed out. Please try again."
    case .videoStreamingError:
      return "Video streaming failed. Please try again."
    case .thermalCritical, .thermalEmergency:
      return "The glasses are too hot to keep streaming. Let them cool down and try again."
    case .batteryCritical, .peakPowerShutdown:
      return "The glasses are out of battery. Charge them and try again."
    case .photoCaptureFailed:
      return "Couldn't capture the photo. Try again in a moment."
    case .permissionDenied:
      return "Camera permission denied. Please grant permission in Settings."
    case .hingesClosed:
      return "The hinges on the glasses were closed. Please open the hinges and try again."
    @unknown default:
      return "An unknown streaming error occurred."
    }
  }
}

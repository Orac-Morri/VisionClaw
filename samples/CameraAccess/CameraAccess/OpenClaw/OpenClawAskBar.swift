//
//  OpenClawAskBar.swift
//  CameraAccess
//
//  A text ask strip over the glasses viewfinder: type a question, and it is sent to the
//  OpenClaw gateway together with the frame currently on screen.
//
//  This replaces the ask bar that was removed in Aug 2026 alongside the original direct
//  OpenClaw client. The client underneath (OpenClawService/OpenClawProtocol/
//  OpenClawDeviceIdentity) is ported from OpenVision, where it is proven in daily use.
//
//  Pairing: the device identity lives in the Keychain under "ai.openclaw.visionclaw", separate
//  from OpenVision's. The gateway therefore sees VisionClaw as its own device and will refuse
//  the first connection with NOT_PAIRED until it is approved once on the gateway host:
//
//      openclaw devices list
//      openclaw devices approve <requestId>
//
//  That is expected on first run, not a fault.
//

import SwiftUI
import UIKit

// MARK: - Model

@MainActor
final class OpenClawAskModel: ObservableObject {
  @Published var question: String = ""
  @Published var answer: String?
  @Published var isBusy: Bool = false
  @Published var status: String?

  // OpenClawService is a singleton (`private init`), matching how OpenVision uses it — one
  // socket per app, shared by every caller.
  private let service = OpenClawService.shared
  private var wired = false

  /// Wire the service callbacks once. Called lazily so the socket is only touched on first use —
  /// the gateway link is deliberately not opened at launch.
  private func wireIfNeeded() {
    guard !wired else { return }
    wired = true

    service.onAgentMessage = { [weak self] text in
      Task { @MainActor in
        self?.answer = text
        self?.isBusy = false
        self?.status = nil
      }
    }
    service.onProcessingChanged = { [weak self] processing in
      Task { @MainActor in self?.isBusy = processing }
    }
    service.onConnectionStateChanged = { [weak self] state in
      Task { @MainActor in
        switch state {
        case .connected, .disconnected: self?.status = nil
        case .failed(let msg): self?.status = msg
        default: self?.status = state.description
        }
      }
    }
  }

  /// Send the typed question plus the current viewfinder frame.
  ///
  /// `frame` is whatever the DAT pipeline last decoded. It may legitimately be nil (stream not
  /// started, or no frame yet), in which case the question is sent as text only rather than
  /// failing — asking "what did I just look at?" without an image is still useful.
  func ask(frame: UIImage?) async {
    let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !isBusy else { return }

    wireIfNeeded()
    isBusy = true
    answer = nil
    status = "Connecting…"

    do {
      if !service.connectionState.isUsable {
        try await service.connect()
      }
      status = "Sending…"
      // 0.8 matches OpenVision's capture quality — a good size/detail trade for a VLM.
      let jpeg = frame?.jpegData(compressionQuality: 0.8)
      try await service.sendMessage(text, imageData: jpeg)
      question = ""
      status = nil
    } catch {
      isBusy = false
      status = error.localizedDescription
    }
  }
}

// MARK: - View

struct OpenClawAskBar: View {
  /// The frame to attach — passed in so the bar stays decoupled from the streaming view model.
  let currentFrame: UIImage?

  @StateObject private var model = OpenClawAskModel()
  @State private var expanded = false
  @State private var unread = false
  @FocusState private var focused: Bool

  var body: some View {
    // Trailing alignment keeps the collapsed pill clear of the call button, which sits on the
    // leading side of the control row, and of the centred shutter.
    VStack(alignment: .trailing, spacing: 10) {
      if expanded {
        if let answer = model.answer {
          answerCard(answer)
        }
        if let status = model.status {
          Text(status)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.black.opacity(0.5), in: Capsule())
        }
        inputRow
      } else {
        collapsedPill
      }
    }
    .animation(.easeInOut(duration: 0.22), value: expanded)
    .animation(.easeInOut(duration: 0.22), value: model.answer)
    .onChange(of: model.answer) { newValue in
      // A reply that lands while collapsed shouldn't be lost silently.
      if newValue != nil && !expanded { unread = true }
    }
  }

  // MARK: - Pieces

  /// Compact entry point. Deliberately small: this sits over a live camera view, and a
  /// permanently-open text field hides the thing the wearer is trying to look at.
  private var collapsedPill: some View {
    Button {
      expanded = true
      unread = false
      focused = true
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "bubble.left.and.text.bubble.right.fill")
          .font(.system(size: 15, weight: .semibold))
        Text("Ask")
          .font(.subheadline.weight(.semibold))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .background(.black.opacity(0.5), in: Capsule())
      .overlay(alignment: .topTrailing) {
        if unread {
          Circle()
            .fill(.green)
            .frame(width: 9, height: 9)
            .offset(x: 3, y: -3)
        }
      }
    }
    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
  }

  private func answerCard(_ answer: String) -> some View {
    ScrollView {
      Text(answer)
        .font(.callout)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
    .frame(maxHeight: 170)
    .padding(12)
    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
    .transition(.opacity)
  }

  private var inputRow: some View {
    HStack(spacing: 8) {
      Button {
        focused = false
        expanded = false
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(.white.opacity(0.9))
          .frame(width: 32, height: 32)
          .background(.black.opacity(0.5), in: Circle())
      }

      TextField("Ask about what you're seeing…", text: $model.question)
        .textFieldStyle(.plain)
        .foregroundStyle(.white)
        .tint(.white)
        .submitLabel(.send)
        .focused($focused)
        .onSubmit { send() }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: Capsule())

      Button(action: send) {
        Group {
          if model.isBusy {
            ProgressView().tint(.white)
          } else {
            Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
          }
        }
        .frame(width: 34, height: 34)
        .foregroundStyle(.white)
      }
      .disabled(model.isBusy || model.question.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    .transition(.opacity)
  }

  private func send() {
    focused = false
    let frame = currentFrame
    Task { await model.ask(frame: frame) }
  }
}

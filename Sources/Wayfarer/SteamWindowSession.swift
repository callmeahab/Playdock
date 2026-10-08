import AppKit
import AVFoundation
@preconcurrency import ApplicationServices
import Combine
import CoreMedia
import ScreenCaptureKit
import WayfarerCore

struct SteamUIRequest: Identifiable, Equatable {
    enum Destination: Equatable {
        case account, chat, workshop(URL)
        var url: String {
            switch self { case .account: "steam://open/main"; case .chat: "steam://open/friends"; case .workshop(let url): url.absoluteString }
        }
    }
    let id = UUID()
    let platform:GamePlatform
    let root:URL
    let prefix:URL?
    var destination: Destination = .account
    var friendID:String? = nil
    var title:String {
        switch destination {
        case .account: "\(platform.name) Steam"
        case .chat: "\(platform.name) Steam Chat"
        case .workshop: "\(platform.name) Steam Workshop"
        }
    }
    var symbol: String { switch destination { case .account: "person.crop.circle"; case .chat: "bubble.left.and.bubble.right"; case .workshop: "puzzlepiece.extension" } }
}

struct SteamSharedWindow: Identifiable {
    var window: SCWindow
    var id: CGWindowID { window.windowID }
    var title: String { window.title?.isEmpty == false ? window.title! : window.owningApplication?.applicationName ?? "Windows app" }
}

@MainActor
final class SteamWindowSession: NSObject, ObservableObject {
    @Published private(set) var context: SteamUIRequest?
    @Published private(set) var windows: [SteamSharedWindow] = []
    @Published private(set) var selectedWindowID: CGWindowID?
    @Published private(set) var message = "Start Steam to open your session."
    @Published private(set) var capturing = false
    @Published private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()
    @Published private(set) var hasInputPermission = AXIsProcessTrusted()
    @Published private(set) var error: String?
    @Published var interactive = true
    let surface = SteamSharedSurfaceView()
    private var stream: SCStream?
    private var output: SteamSharedFrameOutput?
    private var monitor: Task<Void, Never>?
    private var generation = UUID()
    private var openWindow: (() -> Void)?
    private var presentWindow: ((NSWindow?) -> Void)?
    private var opened=false
    private var userSelectedWindow=false
    private let parking=SteamWindowPlacement()
    private var termination:NSObjectProtocol?

    override init() {
        super.init()
        surface.permissionCheck = { AXIsProcessTrusted() }
        termination=NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func begin(_ context: SteamUIRequest, presentWindow:@escaping (NSWindow?)->Void,openWindow: @escaping () -> Void) {
        end()
        self.openWindow=openWindow; opened=false
        self.presentWindow=presentWindow
        self.context = context
        selectedWindowID = nil
        userSelectedWindow=false
        message = "Waiting for \(context.title)…"
        error = nil
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--permission-preview") {
            hasScreenPermission=false; hasInputPermission=false
            return
        }
        #endif
        restartMonitor()
    }

    func requestScreenPermission() {
        _ = CGRequestScreenCaptureAccess()
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        if !hasScreenPermission { openPrivacy("Privacy_ScreenCapture") }
        restartMonitor()
    }

    func requestInputPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        hasInputPermission = AXIsProcessTrustedWithOptions(options)
        if !hasInputPermission { openPrivacy("Privacy_Accessibility") }
        restartMonitor()
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    func retry() { opened=false; restartMonitor() }

    func refreshPermissions() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--permission-preview") { return }
        #endif
        let screen=CGPreflightScreenCaptureAccess(), input=AXIsProcessTrusted()
        let changed=screen != hasScreenPermission || input != hasInputPermission
        hasScreenPermission=screen; hasInputPermission=input
        if changed { restartMonitor() }
    }

    func chooseWindow(_ id: CGWindowID) {
        userSelectedWindow=true
        selectedWindowID = id
        restartMonitor()
    }

    private let runtimeService = RuntimeProcessService()

    private func restartMonitor() {
        monitor?.cancel()
        error=nil
        generation = UUID()
        let current = generation
        monitor = Task { [weak self] in
            guard let self else { return }
            await stopCapture()
            guard generation == current, !Task.isCancelled else { return }
            while !Task.isCancelled, generation == current, let context {
                hasScreenPermission = CGPreflightScreenCaptureAccess()
                hasInputPermission = AXIsProcessTrusted()
                surface.inputEnabled = interactive && hasInputPermission
                guard hasScreenPermission && hasInputPermission else {
                    presentWindow?(nil)
                    if capturing { await stopCapture() }
                    message = "Allow macOS to display and control Steam inside Wayfarer."
                    try? await Task.sleep(nanoseconds:1_000_000_000)
                    continue
                }
                guard let host=surface.window else { try? await Task.sleep(nanoseconds:100_000_000); continue }
                presentWindow?(host)
                if !opened { opened=true; openWindow?() }
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                    guard generation == current, !Task.isCancelled else { return }
                    let pids = Array(Set(content.windows.compactMap { $0.owningApplication?.processID }))
                    let matchedPIDs = await runtimeService.mainSteamProcesses(pids: pids, root: context.root, prefix: context.prefix, windows: false)
                    guard generation == current, !Task.isCancelled else { return }
                    let found = content.windows.filter { window in
                        guard let app = window.owningApplication, app.processID != getpid(), window.windowLayer == 0,
                              window.frame.width > 80, window.frame.height > 60 else { return false }
                        return matchedPIDs[app.processID] != nil
                    }.sorted { a, b in
                        func score(_ window: SCWindow) -> Double {
                            let title = window.title?.lowercased() ?? ""
                            let exact = ["sign in", "login", "steam guard", "authentication"].contains(where:title.contains) ? 1_000_000_000.0 : 0
                            let steam = title.contains("steam") ? 500_000_000.0 : 0
                            let chat = context.destination == .chat && ["friends", "chat"].contains(where:title.contains) ? 750_000_000.0 : 0
                            return exact + chat + steam + window.frame.width * window.frame.height
                        }
                        return score(a) > score(b)
                    }
                    for window in found { parking.cover(window,host:surface.window) }
                    windows = found.map { SteamSharedWindow(window: $0) }
                    let chosen = (userSelectedWindow ? selectedWindowID.flatMap { id in found.first { $0.windowID == id } } : nil) ?? found.first
                    if let chosen {
                        if selectedWindowID != chosen.windowID || stream == nil {
                            await stopCapture()
                            guard generation == current, !Task.isCancelled else { return }
                            selectedWindowID = chosen.windowID
                            try await capture(chosen, generation: current)
                            guard generation == current, !Task.isCancelled else { return }
                        } else if surface.target?.frame.size != chosen.frame.size, let stream {
                            try await stream.updateConfiguration(configuration(for: chosen))
                        }
                        surface.target = SteamSharedInputTarget(pid: chosen.owningApplication!.processID, windowID: chosen.windowID, frame: parking.frame(for:chosen), token:RuntimeProcessIdentity.token(for:chosen.owningApplication!.processID))
                        message = "\(chosen.title ?? context.title) · \(context.platform.name)"
                    } else {
                        await stopCapture()
                        selectedWindowID = nil
                        surface.target = nil
                        message = "Waiting for \(context.title). Steam may still be updating or signing in."
                    }
                } catch {
                    guard generation == current, !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                    message = "Session display is unavailable."
                    await stopCapture()
                    break
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func capture(_ window: SCWindow, generation: UUID) async throws {
        let config = configuration(for: window)
        let output = SteamSharedFrameOutput(onFailure: { [weak self] text in
            guard let self, self.generation == generation else { return }
            self.error = text; self.capturing = false
        })
        await output.start { [weak self] frame in
            guard let self, self.generation == generation else { return }
            self.surface.display(frame.buffer)
        }
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "app.wayfarer.frames", qos: .userInteractive))
        self.output = output
        self.stream = stream
        try await stream.startCapture()
        guard self.generation == generation else { try? await stream.stopCapture(); return }
        capturing = true
        NSApp.activate(ignoringOtherApps: true)
        (surface.window ?? NSApp.mainWindow)?.makeKeyAndOrderFront(nil)
    }

    private func configuration(for window: SCWindow) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = min(2, 2560 / window.frame.width, 1440 / window.frame.height)
        config.width = max(Int(window.frame.width * scale), 160)
        config.height = max(Int(window.frame.height * scale), 120)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false // Runtime audio already plays through macOS.
        config.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 14.0, *) { config.ignoreShadowsSingleWindow = true }
        return config
    }

    private func stopCapture() async {
        let previous = stream
        stream = nil
        let previousOutput = output; output = nil
        await previousOutput?.finish()
        capturing = false
        surface.releaseInput()
        surface.clear()
        if let previous { try? await previous.stopCapture() }
    }

    func end() {
        presentWindow?(nil); presentWindow=nil
        monitor?.cancel()
        generation = UUID()
        let oldStream = stream, oldOutput = output; stream = nil; output = nil; capturing = false
        surface.releaseInput(); parking.restore()
        context = nil
        openWindow=nil
        windows = []
        selectedWindowID = nil
        surface.target = nil
        surface.clear()
        message = "Session view disconnected."
        Task { await oldOutput?.finish(); try? await oldStream?.stopCapture() }
    }


}

/// Retained, read-only capture buffer shared with the renderer.
private struct SteamSharedFrame: @unchecked Sendable { let buffer: CMSampleBuffer }

/// Buffer only the latest frame; capture callbacks do no rendering.
private actor SteamFrameService {
    private let frames: AsyncStream<SteamSharedFrame>
    nonisolated let continuation: AsyncStream<SteamSharedFrame>.Continuation
    private var delivery: Task<Void, Never>?
    init() {
        let pair = AsyncStream<SteamSharedFrame>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = pair.stream; continuation = pair.continuation
    }
    func start(_ handler: @escaping @MainActor @Sendable (SteamSharedFrame) -> Void) {
        delivery = Task {
            for await frame in frames {
                guard !Task.isCancelled else { return }
                await handler(frame)
            }
        }
    }
    func finish() { continuation.finish(); delivery?.cancel(); delivery = nil }
}

private final class SteamSharedFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    private let frames = SteamFrameService()
    private let onFailure: @MainActor @Sendable (String) -> Void
    init(onFailure: @escaping @MainActor @Sendable (String) -> Void) { self.onFailure = onFailure }
    func start(_ handler: @escaping @MainActor @Sendable (SteamSharedFrame) -> Void) async { await frames.start(handler) }
    func finish() async { await frames.finish() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        frames.continuation.yield(SteamSharedFrame(buffer: sampleBuffer))
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { await onFailure(message) }
    }
}

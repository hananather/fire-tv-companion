import AppKit
import AVFoundation
import AVKit
import CoreGraphics
import UniformTypeIdentifiers

private var tvVideoWindowController: TVVideoWindowController?
let tvVideoSessionDidChange = Notification.Name("TVVideoSessionDidChange")

func centerWindowOnMac(_ window: NSWindow) {
    let screen = NSScreen.screens.first {
        guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
        return CGDisplayIsBuiltin(number.uint32Value) != 0
    } ?? NSScreen.main
    guard let screen = screen else { window.center(); return }
    let area = screen.visibleFrame
    let size = NSSize(width: min(window.frame.width, area.width), height: min(window.frame.height, area.height))
    window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                           width: size.width, height: size.height), display: false)
}

func connectedTVScreen(matchingName name: String?) -> NSScreen? {
    guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
    let target = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    let matches = NSScreen.screens.filter { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              CGDisplayIsBuiltin(number.uint32Value) == 0 else { return false }
        let label = screen.localizedName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return label == target || label == target + " (airplay)"
    }
    return matches.count == 1 ? matches.first : nil
}

func tvVideoSessionIsActive() -> Bool { tvVideoWindowController?.hasTVSession == true }
func setTVVideoTargetName(_ name: String?) { tvVideoWindowController?.setTargetName(name) }

func showTVVideoPlayer(url: URL? = nil, tvName: String? = nil) {
    guard Thread.isMainThread else {
        DispatchQueue.main.async { showTVVideoPlayer(url: url, tvName: tvName) }
        return
    }
    if tvVideoWindowController == nil {
        tvVideoWindowController = TVVideoWindowController()
    }
    guard let controller = tvVideoWindowController else { return }
    controller.prepareForPresentation()
    controller.setTargetName(tvName)
    if controller.window?.isMiniaturized == true { controller.window?.deminiaturize(nil) }
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if let url = url { controller.openVideo(at: url) }
}

private final class TVVideoWindowController: NSWindowController, NSWindowDelegate {
    private var player: AVPlayer?
    private let playerView = AVPlayerView()
    private let routePicker = AVRoutePickerView()
    private let playButton = NSButton(title: "Play", target: nil, action: nil)
    private let showOnTVButton = NSButton(title: "Show on TV", target: nil, action: nil)
    private let bringBackButton = NSButton(title: "Bring back", target: nil, action: nil)
    private let fileLabel = NSTextField(labelWithString: "No video selected")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Open a video to begin.")
    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private var accessedURL: URL?
    private var playbackError: String?
    private var reachedEnd = false
    private var targetName: String?
    private var screenObserver: NSObjectProtocol?

    var hasTVSession: Bool {
        guard window?.isVisible == true || window?.isMiniaturized == true else { return false }
        if player?.isExternalPlaybackActive == true { return true }
        guard let target = connectedTVScreen(matchingName: targetName) else { return false }
        return window?.screen === target
    }

    func setTargetName(_ name: String?) {
        targetName = name
        updateDisplayButtons()
    }

    func prepareForPresentation() {
        if player == nil {
            let currentPlayer = AVPlayer()
            currentPlayer.allowsExternalPlayback = true
            currentPlayer.actionAtItemEnd = .pause
            player = currentPlayer
            playerView.player = currentPlayer
            routePicker.player = currentPlayer
            observations = [
                currentPlayer.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] observedPlayer, _ in
                    DispatchQueue.main.async {
                        guard let self = self, self.player === observedPlayer else { return }
                        self.updateStatus()
                    }
                },
                currentPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
                    DispatchQueue.main.async {
                        guard let self = self, self.player === observedPlayer else { return }
                        self.updateStatus()
                    }
                }
            ]
        }
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.updateDisplayButtons() }
        }
        updateStatus()
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "TV Video"
        window.minSize = NSSize(width: 580, height: 410)
        window.isReleasedWhenClosed = false
        centerWindowOnMac(window)
        super.init(window: window)
        window.delegate = self
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        routePicker.isRoutePickerButtonBordered = true
        routePicker.setAccessibilityLabel("Choose AirPlay output")
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        playButton.bezelStyle = .rounded
        playButton.isEnabled = false
        showOnTVButton.target = self
        showOnTVButton.action = #selector(showOnTV)
        showOnTVButton.bezelStyle = .rounded
        bringBackButton.target = self
        bringBackButton.action = #selector(bringBack)
        bringBackButton.bezelStyle = .rounded
        buildInterface(in: window)
        updateDisplayButtons()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let screenObserver = screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let failureObserver = failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
        }
        if let endObserver = endObserver { NotificationCenter.default.removeObserver(endObserver) }
        accessedURL?.stopAccessingSecurityScopedResource()
    }

    private func buildInterface(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let openButton = NSButton(title: "Open Video…", target: self, action: #selector(chooseVideo))
        openButton.bezelStyle = .rounded
        let airPlayLabel = NSTextField(labelWithString: "AirPlay")
        let toolbar = NSStackView(views: [openButton, playButton, fileLabel, showOnTVButton, bringBackButton, airPlayLabel, routePicker])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 12
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fileLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fileLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        let instructions = NSTextField(wrappingLabelWithString:
            "Keep this window visible for TV desktop video. Direct AirPlay media can continue while minimized. Closing releases playback resources. Sound settings controls the Mac’s audio output.")
        instructions.font = .systemFont(ofSize: 12)
        instructions.textColor = .secondaryLabelColor
        for view in [toolbar, playerView, statusLabel, instructions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            routePicker.widthAnchor.constraint(equalToConstant: 42),
            routePicker.heightAnchor.constraint(equalToConstant: 32),
            playerView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            playerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),
            statusLabel.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            instructions.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            instructions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            instructions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            instructions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
    }

    @objc private func chooseVideo() {
        guard let window = window else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Video"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.movie]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openVideo(at: url)
        }
    }

    @objc private func togglePlayback() {
        guard let player = player, let item = player.currentItem else { return }
        if player.timeControlStatus == .paused {
            if reachedEnd, CMTimeCompare(player.currentTime(), item.duration) >= 0 {
                player.seek(to: .zero)
            }
            reachedEnd = false
            player.play()
        }
        else { player.pause() }
    }

    func openVideo(at url: URL) {
        guard url.isFileURL else {
            reportError("Choose a video file saved on this Mac.")
            return
        }
        let scopedAccess = url.startAccessingSecurityScopedResource()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            if scopedAccess { url.stopAccessingSecurityScopedResource() }
            reportError("This video could not be opened. Check that the file is available and readable.")
            return
        }
        prepareForPresentation()
        guard let player = player else {
            if scopedAccess { url.stopAccessingSecurityScopedResource() }
            return
        }
        player.pause()
        removeItemObservers()
        player.replaceCurrentItem(with: nil)
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = scopedAccess ? url : nil
        playbackError = nil
        reachedEnd = false
        fileLabel.stringValue = url.lastPathComponent
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self, self.player?.currentItem === item else { return }
                if item.status == .failed {
                    self.reportError(item.error?.localizedDescription ?? "This video format could not be played.")
                } else {
                    self.updateStatus()
                }
            }
        }
        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] notification in
            guard let self = self, let notifiedItem = notification.object as? AVPlayerItem,
                  self.player?.currentItem === notifiedItem else { return }
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self.reportError(error?.localizedDescription ?? "Playback stopped because the video could not be played.")
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] notification in
            guard let self = self, let notifiedItem = notification.object as? AVPlayerItem,
                  self.player?.currentItem === notifiedItem else { return }
            self.player?.pause()
            self.reachedEnd = true
            self.updateStatus()
        }
        updateStatus()
    }

    private func updateStatus() {
        playButton.isEnabled = player?.currentItem?.status == .readyToPlay
        playButton.title = player == nil || player?.timeControlStatus == .paused ? "Play" : "Pause"
        NotificationCenter.default.post(name: tvVideoSessionDidChange, object: nil)
        if let error = playbackError {
            statusLabel.stringValue = "Unable to play: \(error)"
            statusLabel.textColor = .systemRed
            return
        }
        statusLabel.textColor = .labelColor
        guard let player = player, let item = player.currentItem else {
            statusLabel.stringValue = "Open a video to begin."
            return
        }
        guard item.status == .readyToPlay else {
            statusLabel.stringValue = "Loading video…"
            return
        }
        let onTV = connectedTVScreen(matchingName: targetName).map { window?.screen === $0 } ?? false
        let output = player.isExternalPlaybackActive ? "AirPlay media output" : onTV ? "TV desktop" : "Mac desktop"
        switch player.timeControlStatus {
        case .playing: statusLabel.stringValue = "Playing · \(output)"
        case .waitingToPlayAtSpecifiedRate: statusLabel.stringValue = "Waiting for playback · \(output)"
        case .paused: statusLabel.stringValue = "Ready or paused · \(output)"
        @unknown default: statusLabel.stringValue = output
        }
    }

    private func reportError(_ message: String) {
        playbackError = message
        updateStatus()
    }

    func windowWillClose(_ notification: Notification) {
        player?.pause()
        removeItemObservers()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        player?.currentItem?.cancelPendingSeeks()
        player?.replaceCurrentItem(with: nil)
        playerView.player = nil
        routePicker.player = nil
        player = nil
        if let screenObserver = screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        playbackError = nil
        reachedEnd = false
        fileLabel.stringValue = "No video selected"
        updateStatus()
        DispatchQueue.main.async { [weak self] in
            if let self = self, tvVideoWindowController === self,
               self.window?.isVisible != true, self.window?.isMiniaturized != true {
                tvVideoWindowController = nil
            }
            NotificationCenter.default.post(name: tvVideoSessionDidChange, object: nil)
        }
    }

    private func removeItemObservers() {
        itemObservation?.invalidate()
        itemObservation = nil
        for observer in [failureObserver, endObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        failureObserver = nil
        endObserver = nil
    }

    private func updateDisplayButtons() {
        let target = connectedTVScreen(matchingName: targetName)
        if let number = target?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            showOnTVButton.isEnabled = CGDisplayMirrorsDisplay(number.uint32Value) == kCGNullDirectDisplay
        } else { showOnTVButton.isEnabled = false }
        showOnTVButton.toolTip = showOnTVButton.isEnabled ? "Move this video window to your TV" : "Connect the selected TV as an extended display first"
        bringBackButton.isEnabled = target != nil && window?.screen === target
    }

    @objc private func showOnTV() {
        guard let target = connectedTVScreen(matchingName: targetName),
              let number = target.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              CGDisplayMirrorsDisplay(number.uint32Value) == kCGNullDirectDisplay else {
            statusLabel.stringValue = "Connect your selected TV with Screen Mirroring and choose Extend first."
            return
        }
        moveWindow(to: target)
    }

    @objc private func bringBack() {
        let target = NSScreen.screens.first {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        } ?? NSScreen.screens.first { $0 !== connectedTVScreen(matchingName: targetName) }
        if let target = target { moveWindow(to: target) }
    }

    private func moveWindow(to screen: NSScreen) {
        guard let window = window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        let available = screen.visibleFrame
        let size = NSSize(width: min(window.frame.width, available.width), height: min(window.frame.height, available.height))
        let frame = NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                           width: size.width, height: size.height)
        window.setFrame(frame, display: true, animate: true)
        window.makeKeyAndOrderFront(nil)
        updateDisplayButtons()
        updateStatus()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateDisplayButtons()
        updateStatus()
    }
}

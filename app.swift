import AppKit
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

private struct TVChoice {
    let id: String
    let name: String
    let host: String
    let deviceID: String?
    let saved: Bool
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var awakeMenuItem: NSMenuItem!
    private let devicePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(wrappingLabelWithString: "Searching for TVs on your Wi-Fi…")
    private let connection = NSTextField(labelWithString: "Remote not paired")
    private let displayStatus = NSTextField(labelWithString: "TV display not connected")
    private let pin = NSTextField()
    private let text = NSTextField()
    private let appPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let audioPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private var audioOutputs: [AudioOutput] = []
    private let remotePad = RemotePadView()
    private var remoteButtons: [NSButton] = []
    private var showCodeButton: NSButton!
    private var pairButton: NSButton!
    private var retryButton: NSButton!
    private var installedApps: [InstalledApp] = []
    private var discovered: [DiscoveredTV] = []
    private var choices: [TVChoice] = []
    private var selected: TVChoice?
    private var savedConfiguration: PairingConfiguration?
    private var activeConfiguration: PairingConfiguration?
    private var client: FireTVClient?
    private var pairingClient: FireTVClient?
    private var isBusy = false
    private var generation = 0
    private var commandsSent = 0
    private var observers: [NSObjectProtocol] = []
    private var keepAwake = false
    private var assertion: IOPMAssertionID = 0
    private lazy var discovery = TVDiscovery { [weak self] devices in
        self?.discovered = devices
        if self?.isBusy == false { self?.rebuildDevices() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 790),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Fire TV Companion"
        centerWindowOnMac(window)
        window.isReleasedWhenClosed = false
        buildInterface()
        refreshAudioOutputs()
        do { savedConfiguration = try PairingConfiguration.load() }
        catch { showError(error) }
        rebuildDevices()
        discovery.start()
        for name in [NSApplication.didChangeScreenParametersNotification, tvVideoSessionDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.updateConnection()
            })
        }
        if !CommandLine.arguments.contains("--background") { showRemote() }
        if client != nil { refreshApps(silent: true, retries: 2) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showRemote()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        discovery.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        releaseAssertion()
    }

    private func buildMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Fire TV Companion", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Fire TV Companion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "tv", accessibilityDescription: "Fire TV Companion")
        let statusMenu = NSMenu()
        for (title, action) in [("Remote", #selector(showRemote)), ("Dashboard", #selector(showDashboard)), ("Video", #selector(showVideo)),
                                ("Display settings", #selector(showDisplaySettings)), ("Sound settings", #selector(showSoundSettings))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            statusMenu.addItem(item)
        }
        statusMenu.addItem(.separator())
        awakeMenuItem = NSMenuItem(title: "Keep awake during TV session", action: #selector(toggleKeepAwake), keyEquivalent: "")
        awakeMenuItem.target = self
        statusMenu.addItem(awakeMenuItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = statusMenu
    }

    @objc private func showRemote() {
        refreshAudioOutputs()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func showVideo() { showTVVideoPlayer(tvName: selected?.name) }
    @objc private func showDashboard() { showTVDashboard(tvName: selected?.name) }
    @objc private func showDisplaySettings() { openSettings("displays") }
    @objc private func showSoundSettings() { openSettings("sound") }
    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.\(pane)") { NSWorkspace.shared.open(url) }
    }
    private func refreshAudioOutputs() {
        audioOutputs = AudioRouting.outputs()
        audioPicker.removeAllItems()
        audioPicker.addItem(withTitle: "Choose audio output…")
        audioPicker.addItems(withTitles: audioOutputs.map { $0.name })
        if let id = AudioRouting.currentDefaultOutputID(), let index = audioOutputs.firstIndex(where: { $0.id == id }) {
            audioPicker.selectItem(at: index + 1)
        }
    }
    @objc private func selectAudioOutput() {
        let index = audioPicker.indexOfSelectedItem - 1
        guard audioOutputs.indices.contains(index) else { return }
        do {
            try AudioRouting.selectOutput(id: audioOutputs[index].id)
            if !isBusy { status.stringValue = "Mac audio output: \(audioOutputs[index].name)." }
        } catch { status.stringValue = error.localizedDescription }
        refreshAudioOutputs()
    }
    @objc private func toggleKeepAwake() {
        keepAwake.toggle()
        awakeMenuItem.state = keepAwake ? .on : .off
        updateKeepAwake()
    }
    private func updateKeepAwake() {
        let sessionActive = connectedTVScreen(matchingName: selected?.name) != nil || tvVideoSessionIsActive()
        if keepAwake && sessionActive && assertion == 0 {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Fire TV Companion TV session" as CFString, &assertion)
            if result != kIOReturnSuccess {
                assertion = 0
                status.stringValue = "The Mac could not keep this TV session awake."
            }
        } else if !keepAwake || !sessionActive { releaseAssertion() }
    }
    private func releaseAssertion() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
    }

    private func button(_ title: String, width: CGFloat? = nil, remote: Bool = true,
                        action: @escaping () -> Void) -> NSButton {
        let result = ActionButton(title: title, action: action)
        result.translatesAutoresizingMaskIntoConstraints = false
        result.heightAnchor.constraint(equalToConstant: 32).isActive = true
        if let width = width { result.widthAnchor.constraint(equalToConstant: width).isActive = true }
        if remote { remoteButtons.append(result) }
        return result
    }
    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = .horizontal
        result.alignment = .centerY
        result.spacing = spacing
        return result
    }
    private func buildInterface() {
        guard let content = window.contentView else { return }
        let title = NSTextField(labelWithString: "Fire TV Companion")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        devicePicker.target = self
        devicePicker.action = #selector(selectDevice)
        devicePicker.translatesAutoresizingMaskIntoConstraints = false
        devicePicker.widthAnchor.constraint(equalToConstant: 280).isActive = true
        retryButton = button("Retry", width: 64, remote: false) { [weak self] in self?.retryConnection() }
        pin.placeholderString = "TV code"
        pin.translatesAutoresizingMaskIntoConstraints = false
        pin.widthAnchor.constraint(equalToConstant: 82).isActive = true
        showCodeButton = button("Show TV code", remote: false) { [weak self] in self?.displayPin() }
        pairButton = button("Pair", remote: false) { [weak self] in self?.verifyPin() }
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        status.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        for label in [connection, displayStatus] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        let padButton: (String, String) -> NSButton = { title, action in
            self.button(title, width: 80) { [weak self] in self?.navigate(action) }
        }
        let padStack = NSStackView(views: [row([padButton("↑", "dpad_up")]),
            row([padButton("←", "dpad_left"), padButton("OK", "select"), padButton("→", "dpad_right")]),
            row([padButton("↓", "dpad_down")])])
        padStack.orientation = .vertical
        padStack.alignment = .centerX
        padStack.spacing = 4
        padStack.translatesAutoresizingMaskIntoConstraints = false
        remotePad.translatesAutoresizingMaskIntoConstraints = false
        remotePad.addSubview(padStack)
        NSLayoutConstraint.activate([
            padStack.topAnchor.constraint(equalTo: remotePad.topAnchor, constant: 5),
            padStack.bottomAnchor.constraint(equalTo: remotePad.bottomAnchor, constant: -5),
            padStack.leadingAnchor.constraint(equalTo: remotePad.leadingAnchor, constant: 8),
            padStack.trailingAnchor.constraint(equalTo: remotePad.trailingAnchor, constant: -8)])
        remotePad.command = { [weak self] key in
            let actions: [UInt16: String] = [123: "dpad_left", 124: "dpad_right", 125: "dpad_down", 126: "dpad_up", 36: "select", 76: "select", 53: "back"]
            if let action = actions[key] { self?.navigate(action) }
            else if key == 49 { self?.send("/v1/media?action=play") }
        }
        let home = padButton("Home", "home")
        let back = padButton("Back", "back")
        let options = padButton("Menu", "menu")
        let play = button("Play / pause", width: 108) { [weak self] in self?.send("/v1/media?action=play") }
        let wake = button("Wake TV", width: 76) { [weak self] in self?.wakeTV() }
        let volumeDown = padButton("Volume −", "volume_down")
        let volumeUp = padButton("Volume +", "volume_up")
        appPicker.addItem(withTitle: "Load installed apps")
        appPicker.translatesAutoresizingMaskIntoConstraints = false
        appPicker.widthAnchor.constraint(equalToConstant: 228).isActive = true
        let refresh = button("↻", width: 38) { [weak self] in self?.refreshApps() }
        refresh.toolTip = "Refresh installed apps"
        let launch = button("Open", width: 64) { [weak self] in self?.launchApp() }
        text.placeholderString = "Text for the TV’s active input"
        text.translatesAutoresizingMaskIntoConstraints = false
        text.widthAnchor.constraint(equalToConstant: 274).isActive = true
        let sendText = button("Send", width: 64) { [weak self] in self?.sendText() }
        let displays = button("Display settings", remote: false) { [weak self] in self?.showDisplaySettings() }
        let video = button("Video", remote: false) { [weak self] in self?.showVideo() }
        let testVideo = button("Connection test", remote: false) { [weak self] in
            showTVVideoPlayer(url: Bundle.main.url(forResource: "test-video", withExtension: "mp4"), tvName: self?.selected?.name)
        }
        let sound = button("Sound settings", remote: false) { [weak self] in self?.showSoundSettings() }
        let dashboard = button("Dashboard", remote: false) { [weak self] in self?.showDashboard() }
        audioPicker.target = self
        audioPicker.action = #selector(selectAudioOutput)
        audioPicker.translatesAutoresizingMaskIntoConstraints = false
        audioPicker.widthAnchor.constraint(equalToConstant: 228).isActive = true
        audioPicker.toolTip = "Mac media audio output. Direct AirPlay video uses the video player’s selected route."
        let refreshAudio = button("↻", width: 38, remote: false) { [weak self] in self?.refreshAudioOutputs() }
        refreshAudio.toolTip = "Refresh audio outputs"
        let keyboardNote = NSTextField(labelWithString: "Click the remote pad to use arrows, Return, and Space.")
        keyboardNote.font = .systemFont(ofSize: 11)
        keyboardNote.textColor = .secondaryLabelColor
        let note = NSTextField(wrappingLabelWithString:
            "For a second desktop: Control Center → Screen Mirroring → your TV → Extend. If the TV is missing, open Connection test and choose it with AirPlay first. In Video, Show on TV moves the video to the connected TV desktop.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, row([devicePicker, retryButton]), connection, displayStatus,
            row([showCodeButton, pin, pairButton]), status, remotePad, row([home, back, options]),
            row([play, wake, volumeDown, volumeUp]), keyboardNote, row([appPicker, refresh, launch]),
            row([text, sendText]), row([displays, video, testVideo]), row([audioPicker, refreshAudio]), row([dashboard, sound]), note])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor), note.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        updateControls()
    }

    private func rebuildDevices() {
        let previous = selected?.id
        choices = []
        if let saved = savedConfiguration {
            let matched = discovered.first {
                if let id = saved.deviceID { return $0.deviceID.caseInsensitiveCompare(id) == .orderedSame }
                return $0.host == saved.host
            }
            choices.append(TVChoice(id: saved.deviceID ?? "saved:\(saved.host)", name: matched?.name ?? saved.name ?? "Paired TV",
                host: matched?.host ?? saved.host, deviceID: matched?.deviceID ?? saved.deviceID, saved: true))
        }
        for tv in discovered where !choices.contains(where: {
            $0.deviceID?.caseInsensitiveCompare(tv.deviceID) == .orderedSame || $0.host == tv.host
        }) {
            choices.append(TVChoice(id: tv.deviceID, name: tv.name, host: tv.host, deviceID: tv.deviceID, saved: false))
        }
        devicePicker.removeAllItems()
        devicePicker.addItem(withTitle: choices.isEmpty ? "Searching for TVs…" : "Choose a TV…")
        devicePicker.addItems(withTitles: choices.map { "\($0.name) · \($0.host)\($0.saved ? " · saved" : "")" })
        let chosen = previous.flatMap { id in choices.firstIndex { $0.id == id } }
            ?? selected.flatMap { selected in choices.firstIndex { $0.host == selected.host && $0.saved == selected.saved } }
            ?? (previous == nil ? choices.firstIndex { $0.saved } : nil)
        if let index = chosen {
            devicePicker.selectItem(at: index + 1)
            if selected?.id != choices[index].id || selected?.host != choices[index].host { configureSelection(choices[index]) }
            else {
                selected = choices[index]
                if choices[index].saved {
                    activeConfiguration?.name = choices[index].name
                    activeConfiguration?.deviceID = choices[index].deviceID
                }
            }
        } else if selected != nil { configureSelection(nil) }
        updateControls()
        updateConnection()
    }
    @objc private func selectDevice() {
        let index = devicePicker.indexOfSelectedItem - 1
        configureSelection(choices.indices.contains(index) ? choices[index] : nil)
        if client != nil { refreshApps(silent: true, retries: 1) }
    }
    private func configureSelection(_ choice: TVChoice?) {
        generation += 1
        selected = choice
        pairingClient = nil
        pin.stringValue = ""
        installedApps = []
        appPicker.removeAllItems()
        appPicker.addItem(withTitle: "Load installed apps")
        client = nil
        activeConfiguration = nil
        commandsSent = 0
        if let choice = choice, choice.saved, var configuration = savedConfiguration {
            configuration.host = choice.host
            configuration.deviceID = choice.deviceID
            configuration.name = choice.name
            activeConfiguration = configuration
            if let token = configuration.token, !token.isEmpty { client = FireTVClient(configuration) }
        }
        if let choice = choice {
            status.stringValue = client == nil ? "Show a TV code to pair this Mac with \(choice.name)." : "Paired. Ready to control \(choice.name)."
        } else { status.stringValue = "Choose your TV. Allow Local Network access if asked, then click Retry." }
        updateControls()
        updateConnection()
    }
    private func updateControls() {
        remoteButtons.forEach { $0.isEnabled = !isBusy && client != nil }
        devicePicker.isEnabled = !isBusy
        retryButton?.isEnabled = !isBusy
        showCodeButton?.isEnabled = !isBusy && selected != nil
        pairButton?.isEnabled = !isBusy && pairingClient != nil
        pin.isEnabled = !isBusy && pairingClient != nil
        text.isEnabled = !isBusy && client != nil
        appPicker.isEnabled = !isBusy && client != nil
    }
    private func updateConnection() {
        setTVVideoTargetName(selected?.name)
        connection.stringValue = client == nil ? "Remote not paired" : "Remote paired · \(commandsSent) commands sent"
        if let screen = connectedTVScreen(matchingName: selected?.name),
           let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let mode = CGDisplayMirrorsDisplay(number.uint32Value) == kCGNullDirectDisplay ? "extended" : "mirrored"
            displayStatus.stringValue = "TV display connected · \(mode)"
        } else { displayStatus.stringValue = "TV display not connected" }
        updateKeepAwake()
    }
    private func setBusy(_ busy: Bool, _ message: String? = nil) {
        isBusy = busy
        if let message = message { status.stringValue = message }
        updateControls()
        if !busy { rebuildDevices() }
    }
    private func showError(_ error: Error) {
        setBusy(false)
        if isTemporarilyUnavailable(error) {
            status.stringValue = "TV unavailable. Check the same Wi-Fi and this app’s Local Network access in System Settings → Privacy & Security, then click Retry."
        } else if let error = error as? URLError,
           [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut].contains(error.code) {
            status.stringValue = "TV unavailable. Check the same Wi-Fi and this app’s Local Network access in System Settings → Privacy & Security, then click Retry."
        } else if let error = error as? URLError, error.code == .cancelled || error.code == .serverCertificateUntrusted {
            status.stringValue = "The TV’s secure connection could not be verified. Use Show TV code to pair again."
        } else { status.stringValue = error.localizedDescription }
    }
    private func isTemporarilyUnavailable(_ error: Error) -> Bool {
        if let error = error as? CompanionError {
            switch error {
            case .tvUnavailable: return true
            default: return false
            }
        }
        if let error = error as? URLError {
            return [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost].contains(error.code)
        }
        return false
    }
    private func retryConnection() {
        guard !isBusy else { return }
        discovery.stop()
        discovery.start()
        status.stringValue = "Searching for your TV. Allow Local Network access if asked."
        if client != nil { refreshApps(silent: false, retries: 2) }
    }

    private func displayPin() {
        guard !isBusy, let choice = selected else { return }
        let requestGeneration = generation
        pairingClient = nil
        let configuration = PairingConfiguration(host: choice.host, certificateSha256: "", token: nil,
                                                 deviceID: choice.deviceID, name: choice.name)
        let wakeClient = FireTVClient(configuration)
        setBusy(true, "Waking \(choice.name) and requesting a TV code…")
        wakeClient.request("POST", "/apps/FireTVRemote", authenticated: false, wake: true) { [weak self] result in
            guard let self = self, self.generation == requestGeneration else { return }
            switch result {
            case .failure(let error): self.showError(error)
            case .success:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    self.probePairingCertificate(choice, generation: requestGeneration, remaining: 3)
                }
            }
        }
    }
    private func probePairingCertificate(_ choice: TVChoice, generation requestGeneration: Int, remaining: Int) {
        guard generation == requestGeneration else { return }
        FireTVClient.probeCertificate(host: choice.host) { [weak self] result in
            guard let self = self, self.generation == requestGeneration else { return }
            switch result {
            case .failure(let error):
                if self.isTemporarilyUnavailable(error), remaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        self.probePairingCertificate(choice, generation: requestGeneration, remaining: remaining - 1)
                    }
                } else { self.showError(error) }
            case .success(let certificate):
                let configuration = PairingConfiguration(host: choice.host, certificateSha256: certificate, token: nil,
                                                         deviceID: choice.deviceID, name: choice.name)
                let pending = FireTVClient(configuration)
                self.pairingClient = pending
                self.requestPin(pending, generation: requestGeneration, remaining: 3)
            }
        }
    }
    private func requestPin(_ pending: FireTVClient, generation requestGeneration: Int, remaining: Int) {
        pending.request("POST", "/v1/FireTV/pin/display", body: ["friendlyName": "Fire TV Companion"], authenticated: false) { [weak self] result in
            guard let self = self, self.generation == requestGeneration else { return }
            switch result {
            case .success:
                self.pin.stringValue = ""
                self.setBusy(false, "Enter the four-digit code shown on your TV, then click Pair.")
                self.window.makeFirstResponder(self.pin)
            case .failure(let error):
                if self.isTemporarilyUnavailable(error), remaining > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        self.requestPin(pending, generation: requestGeneration, remaining: remaining - 1)
                    }
                } else { self.showError(error) }
            }
        }
    }
    private func verifyPin() {
        guard !isBusy, let pending = pairingClient else { return }
        let code = pin.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 4, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            status.stringValue = "Enter the four-digit TV code."
            return
        }
        setBusy(true, "Pairing with your TV…")
        verify(code, client: pending, generation: generation, remaining: 2)
    }
    private func verify(_ code: String, client pending: FireTVClient, generation requestGeneration: Int, remaining: Int) {
        pending.request("POST", "/v1/FireTV/pin/verify", body: ["pin": code], authenticated: false) { [weak self] result in
            guard let self = self, self.generation == requestGeneration else { return }
            switch result {
            case .failure(let error): self.showError(error)
            case .success(let data):
                do {
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let token = object?["description"] as? String ?? ""
                    if token == "OK" || token.isEmpty {
                        if remaining > 0 {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                self.verify(code, client: pending, generation: requestGeneration, remaining: remaining - 1)
                            }
                        } else { self.showError(CompanionError.pinPending) }
                        return
                    }
                    var configuration = pending.configuration
                    configuration.token = token
                    try configuration.save()
                    self.savedConfiguration = configuration
                    self.activeConfiguration = configuration
                    self.client = FireTVClient(configuration)
                    self.pairingClient = nil
                    self.pin.stringValue = ""
                    self.setBusy(false, "Paired. Ready to control your TV.")
                    self.refreshApps(silent: true)
                } catch { self.showError(error) }
            }
        }
    }

    private func navigate(_ action: String) {
        window.makeFirstResponder(remotePad)
        send("/v1/FireTV?action=\(action)")
    }
    private func send(_ path: String, body: [String: String]? = nil) {
        guard !isBusy, let client = client else { return }
        let requestGeneration = generation
        setBusy(true, "Sending to the TV…")
        client.request("POST", path, body: body) { [weak self] result in
            guard let self = self, self.generation == requestGeneration else { return }
            switch result {
            case .success:
                self.commandsSent += 1
                let saved = self.saveConfirmedAddress()
                self.setBusy(false, saved ? "Command sent." : "Command sent. The updated TV address could not be saved.")
                self.updateConnection()
            case .failure(let error): self.showError(error)
            }
        }
    }
    private func wakeTV() {
        guard !isBusy, let client = client else { return }
        let requestGeneration = generation
        setBusy(true, "Sending a wake request…")
        client.request("POST", "/apps/FireTVRemote", authenticated: false, wake: true) { [weak self] result in
            guard let self = self, self.generation == requestGeneration else { return }
            switch result {
            case .success: self.setBusy(false, "Wake request sent.")
            case .failure(let error): self.showError(error)
            }
        }
    }
    private func refreshApps(silent: Bool = false, retries: Int = 1) {
        guard !isBusy, let client = client else { return }
        setBusy(true, silent ? "Connecting to your paired TV…" : "Loading installed apps…")
        loadApps(client, generation: generation, remaining: retries)
    }
    private func loadApps(_ client: FireTVClient, generation requestGeneration: Int, remaining: Int) {
        client.request("GET", "/v1/FireTV/appsV2") { [weak self] result in
            guard let self = self, self.generation == requestGeneration else { return }
            switch result {
            case .failure(let error):
                if self.isTemporarilyUnavailable(error), remaining > 0 {
                    self.status.stringValue = "Waiting for the TV. Allow Local Network access if asked…"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.loadApps(client, generation: requestGeneration, remaining: remaining - 1)
                    }
                } else { self.showError(error) }
            case .success(let data):
                do {
                    self.installedApps = try JSONDecoder().decode([InstalledApp].self, from: data)
                        .filter { $0.isInstalled && !$0.name.isEmpty }
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    self.appPicker.removeAllItems()
                    self.appPicker.addItems(withTitles: self.installedApps.map { $0.name })
                    if self.installedApps.isEmpty { self.appPicker.addItem(withTitle: "No installed apps found") }
                    let saved = self.saveConfirmedAddress()
                    self.setBusy(false, saved ? "Connected. Installed apps loaded." : "Connected. The updated TV address could not be saved.")
                    self.updateConnection()
                } catch { self.showError(error) }
            }
        }
    }
    private func saveConfirmedAddress() -> Bool {
        guard let configuration = activeConfiguration, let saved = savedConfiguration,
              configuration.host != saved.host || configuration.deviceID != saved.deviceID || configuration.name != saved.name else { return true }
        do { try configuration.save(); savedConfiguration = configuration; return true }
        catch { return false }
    }
    private func launchApp() {
        let index = appPicker.indexOfSelectedItem
        guard installedApps.indices.contains(index) else { status.stringValue = "Refresh the installed apps first."; return }
        let identifier = installedApps[index].appId
        guard !identifier.isEmpty, identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            status.stringValue = "This app identifier cannot be opened."
            return
        }
        send("/v1/FireTV/app/\(identifier)")
    }
    private func sendText() {
        guard !text.stringValue.isEmpty else { status.stringValue = "Enter text, with a text field active on the TV."; return }
        send("/v1/FireTV/keyboard", body: ["text": text.stringValue])
    }
}

final class ActionButton: NSButton {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(invoke)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { handler() }
}

private final class RemotePadView: NSView {
    var command: ((UInt16) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              [123, 124, 125, 126, 36, 76, 53, 49].contains(event.keyCode) else { super.keyDown(with: event); return }
        command?(event.keyCode)
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8)
            outline.lineWidth = 2
            outline.stroke()
        }
    }
}

@main
struct FireTVCompanion {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}

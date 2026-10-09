import AppKit
import CoreGraphics
import Foundation

private var tvDashboardWindowController: TVDashboardWindowController?

func showTVDashboard(tvName: String? = nil) {
    guard Thread.isMainThread else {
        DispatchQueue.main.async { showTVDashboard(tvName: tvName) }
        return
    }
    if tvDashboardWindowController == nil {
        tvDashboardWindowController = TVDashboardWindowController()
    }
    guard let controller = tvDashboardWindowController else { return }
    controller.setTVName(tvName)
    controller.refreshLaunchTarget()
    if controller.window?.isMiniaturized == true { controller.window?.deminiaturize(nil) }
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}

private final class TVDashboardWindowController: NSWindowController {
    private let calendarURL = URL(string: "https://calendar.google.com/")!
    private let openButton = NSButton(title: "Open Google Calendar", target: nil, action: nil)
    private let displayStatus = NSTextField(wrappingLabelWithString: "Choose your TV in Remote to check its display connection.")
    private let status = NSTextField(wrappingLabelWithString: "Open Google Calendar, then place its window on your TV.")
    private var tvName: String?
    private var screenObserver: NSObjectProtocol?
    private var browserCalendarOpened = false
    private var calendarBrowserURL: URL?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "TV Dashboard"
        window.isReleasedWhenClosed = false
        centerWindowOnMac(window)
        super.init(window: window)
        buildInterface(in: window)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateDisplayStatus() }
    }

    required init?(coder: NSCoder) { nil }
    deinit {
        if let screenObserver = screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func setTVName(_ name: String?) {
        tvName = name
        updateDisplayStatus()
    }

    func refreshLaunchTarget() {
        if runningCalendarApp() != nil {
            openButton.title = "Show Google Calendar"
        } else if installedCalendarAppURL() != nil {
            openButton.title = "Open Google Calendar"
        } else {
            openButton.title = browserCalendarOpened ? "Return to browser" : "Open Google Calendar"
        }
    }

    private func runningCalendarApp() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("Google Calendar") == .orderedSame && !$0.isTerminated
        }
    }

    private func installedCalendarAppURL() -> URL? {
        if let url = runningCalendarApp()?.bundleURL { return url }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Applications/Chrome Apps.localized/Google Calendar.app"),
            home.appendingPathComponent("Applications/Chrome Apps/Google Calendar.app"),
            home.appendingPathComponent("Applications/Google Calendar.app"),
            URL(fileURLWithPath: "/Applications/Google Calendar.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Chrome Apps.localized/Google Calendar.app", isDirectory: true)
        ]
        return candidates.first {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &directory)
                && directory.boolValue && Bundle(url: $0)?.bundleIdentifier != nil
        }
    }

    private func buildInterface(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let title = NSTextField(labelWithString: "Google Calendar on TV")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        openButton.target = self
        openButton.action = #selector(openCalendar)
        openButton.bezelStyle = .rounded
        let newPage = makeButton("Open new calendar page", action: #selector(openNewCalendarPage))
        newPage.toolTip = "Open calendar.google.com in your default browser. This may create another tab."
        let displays = makeButton("Display settings", action: #selector(openDisplaySettings))
        let row = NSStackView(views: [newPage, displays])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        let instructions = NSTextField(wrappingLabelWithString:
            "In Google Calendar’s Window menu, move its window to your TV, then choose Fill. Keep this launcher on your Mac.")
        let privacy = NSTextField(wrappingLabelWithString:
            "Uses your existing Google sign-in. This launcher does not read or copy calendar data.")
        for label in [displayStatus, instructions, privacy] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        status.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [title, displayStatus, openButton, row, instructions, privacy, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18)
        ]
        for label in [displayStatus, instructions, privacy, status] {
            constraints.append(label.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    @objc private func openCalendar() {
        if let app = runningCalendarApp(), app.activate(options: []) {
            status.stringValue = "Google Calendar shown. Use its Window menu to place it on your TV."
            refreshLaunchTarget()
            return
        }
        if let url = installedCalendarAppURL() {
            openApplication(at: url, success: "Google Calendar opened. Use its Window menu to place it on your TV.")
        } else if browserCalendarOpened {
            returnToBrowser()
        } else {
            openNewCalendarPage()
        }
    }

    @objc private func openNewCalendarPage() {
        let browser = NSWorkspace.shared.urlForApplication(toOpen: calendarURL)
        guard NSWorkspace.shared.open(calendarURL) else {
            status.stringValue = "Google Calendar could not be opened in your browser."
            return
        }
        calendarBrowserURL = browser
        browserCalendarOpened = true
        refreshLaunchTarget()
        status.stringValue = installedCalendarAppURL() == nil
            ? "Google Calendar opened in your browser. Return to browser shows the browser without opening another page."
            : "Google Calendar opened in your browser. Select its tab there, or open the installed Google Calendar app above."
    }

    private func returnToBrowser() {
        guard let url = calendarBrowserURL ?? NSWorkspace.shared.urlForApplication(toOpen: calendarURL) else {
            status.stringValue = "The browser could not be found. Open a new calendar page to try again."
            return
        }
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL == url && !$0.isTerminated }),
           app.activate(options: []) {
            status.stringValue = "Browser shown. Select your Google Calendar tab."
            return
        }
        openApplication(at: url, success: "Browser opened. Select your Google Calendar tab.")
    }

    private func openApplication(at url: URL, success: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        openButton.isEnabled = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.openButton.isEnabled = true
                self.status.stringValue = error.map { "Could not open the app: \($0.localizedDescription)" } ?? success
                self.refreshLaunchTarget()
            }
        }
    }

    @objc private func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.displays") { NSWorkspace.shared.open(url) }
    }

    private func updateDisplayStatus() {
        guard let tvName = tvName, !tvName.isEmpty else {
            displayStatus.stringValue = "Choose your TV in Remote to check its display connection."
            return
        }
        guard let screen = connectedTVScreen(matchingName: tvName),
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            displayStatus.stringValue = "TV display not connected. Use Control Center → Screen Mirroring → your TV → Extend."
            return
        }
        let mode = CGDisplayMirrorsDisplay(number.uint32Value) == kCGNullDirectDisplay ? "extended desktop" : "mirrored screen"
        displayStatus.stringValue = "TV connected · \(mode)"
    }
}

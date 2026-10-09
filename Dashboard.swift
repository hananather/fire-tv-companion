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
    controller.refreshInstalledApps()
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
}

private struct DashboardApp {
    let name: String
    let identifier: String
    let url: URL
}

private final class TVDashboardWindowController: NSWindowController {
    private let calendarPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let taskPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let calendarOpen = NSButton(title: "Open Calendar", target: nil, action: nil)
    private let taskOpen = NSButton(title: "Open Tasks", target: nil, action: nil)
    private let calendarLink = NSTextField()
    private let taskLink = NSTextField()
    private let displayStatus = NSTextField(wrappingLabelWithString: "Choose your TV in Remote to check its display connection.")
    private let status = NSTextField(wrappingLabelWithString: "Open your existing calendar and task apps, or use their browser links.")
    private var calendarApps: [DashboardApp] = []
    private var taskApps: [DashboardApp] = []
    private var tvName: String?
    private var screenObserver: NSObjectProtocol?
    private let preferences = UserDefaults.standard

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "TV Dashboard"
        window.isReleasedWhenClosed = false
        centerWindowOnMac(window)
        super.init(window: window)
        buildInterface(in: window)
        calendarLink.stringValue = preferences.string(forKey: "dashboard.calendarLink") ?? ""
        taskLink.stringValue = preferences.string(forKey: "dashboard.taskLink") ?? ""
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

    func refreshInstalledApps() {
        calendarApps = installedApps([
            ("Notion Calendar", "com.cron.electron"), ("Apple Calendar", "com.apple.iCal")
        ])
        taskApps = installedApps([
            ("Notion", "notion.id"), ("Reminders", "com.apple.reminders"), ("Linear", "com.linear")
        ])
        fill(calendarPicker, apps: calendarApps, preference: "dashboard.calendarApp")
        fill(taskPicker, apps: taskApps, preference: "dashboard.taskApp")
        calendarOpen.isEnabled = !calendarApps.isEmpty
        taskOpen.isEnabled = !taskApps.isEmpty
    }

    private func installedApps(_ candidates: [(String, String)]) -> [DashboardApp] {
        candidates.compactMap { name, identifier in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil }
            return DashboardApp(name: name, identifier: identifier, url: url)
        }
    }

    private func fill(_ picker: NSPopUpButton, apps: [DashboardApp], preference: String) {
        picker.removeAllItems()
        if apps.isEmpty {
            picker.addItem(withTitle: "No supported app installed")
            picker.isEnabled = false
            return
        }
        picker.isEnabled = true
        picker.addItems(withTitles: apps.map { $0.name })
        if let saved = preferences.string(forKey: preference), let index = apps.firstIndex(where: { $0.identifier == saved }) {
            picker.selectItem(at: index)
        }
    }

    private func buildInterface(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let title = NSTextField(labelWithString: "Your calendar and tasks on TV")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        displayStatus.font = .systemFont(ofSize: 12)
        displayStatus.textColor = .secondaryLabelColor
        calendarPicker.target = self
        calendarPicker.action = #selector(calendarSelectionChanged)
        taskPicker.target = self
        taskPicker.action = #selector(taskSelectionChanged)
        calendarOpen.target = self
        calendarOpen.action = #selector(openCalendar)
        taskOpen.target = self
        taskOpen.action = #selector(openTasks)
        for button in [calendarOpen, taskOpen] { button.bezelStyle = .rounded }
        for picker in [calendarPicker, taskPicker] {
            picker.translatesAutoresizingMaskIntoConstraints = false
            picker.widthAnchor.constraint(equalToConstant: 220).isActive = true
        }
        calendarLink.placeholderString = "Optional calendar page · https://…"
        taskLink.placeholderString = "Optional tasks / daily goals page · https://…"
        for field in [calendarLink, taskLink] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 420).isActive = true
        }
        let calendarLinkOpen = makeButton("Open link", action: #selector(openCalendarLink))
        let taskLinkOpen = makeButton("Open link", action: #selector(openTaskLink))
        let save = makeButton("Save links", action: #selector(saveLinks))
        let displays = makeButton("Display settings", action: #selector(openDisplaySettings))
        let refresh = makeButton("Refresh apps", action: #selector(refreshApps))
        let instructions = NSTextField(wrappingLabelWithString:
            "Keep this launcher on your Mac. In each calendar or task app, use Window → Move to your TV, then Fill. For calendar and tasks side by side, use Window → Move & Resize → Left or Right. Apps may remember their positions when reopened.")
        instructions.font = .systemFont(ofSize: 12)
        instructions.textColor = .secondaryLabelColor
        let linkNote = NSTextField(wrappingLabelWithString:
            "Links open in your default browser using its existing signed-in session. This launcher does not read or copy your calendar, tasks, or goals.")
        linkNote.font = .systemFont(ofSize: 11)
        linkNote.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [title, displayStatus,
            row([calendarPicker, calendarOpen]), row([taskPicker, taskOpen]), instructions,
            row([calendarLink, calendarLinkOpen]), row([taskLink, taskLinkOpen]),
            row([save, refresh, displays]), linkNote, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            displayStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
            instructions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            linkNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }
    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    @objc private func calendarSelectionChanged() {
        saveAppSelection(calendarPicker, apps: calendarApps, key: "dashboard.calendarApp")
    }
    @objc private func taskSelectionChanged() {
        saveAppSelection(taskPicker, apps: taskApps, key: "dashboard.taskApp")
    }
    private func saveAppSelection(_ picker: NSPopUpButton, apps: [DashboardApp], key: String) {
        guard apps.indices.contains(picker.indexOfSelectedItem) else { return }
        preferences.set(apps[picker.indexOfSelectedItem].identifier, forKey: key)
    }
    @objc private func openCalendar() {
        calendarSelectionChanged()
        openSelectedApp(calendarPicker, apps: calendarApps)
    }
    @objc private func openTasks() {
        taskSelectionChanged()
        openSelectedApp(taskPicker, apps: taskApps)
    }
    private func openSelectedApp(_ picker: NSPopUpButton, apps: [DashboardApp]) {
        guard apps.indices.contains(picker.indexOfSelectedItem) else { return }
        let app = apps[picker.indexOfSelectedItem]
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.status.stringValue = error.map { "Could not open \(app.name): \($0.localizedDescription)" }
                    ?? "Opened \(app.name). Use its Window menu to place it on your TV."
            }
        }
    }

    @objc private func openCalendarLink() { openLink(calendarLink, key: "dashboard.calendarLink") }
    @objc private func openTaskLink() { openLink(taskLink, key: "dashboard.taskLink") }
    private func validatedLink(_ field: NSTextField) throws -> URL? {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        guard let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              let url = components.url else { throw DashboardLinkError.invalid }
        return url
    }
    private func openLink(_ field: NSTextField, key: String) {
        do {
            guard let url = try validatedLink(field) else {
                status.stringValue = "Add a saved HTTPS page link first."
                return
            }
            preferences.set(url.absoluteString, forKey: key)
            status.stringValue = NSWorkspace.shared.open(url)
                ? "Opened the page in your default browser. Use its Window menu to place it on your TV."
                : "The page could not be opened in your browser."
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func saveLinks() {
        do {
            let calendar = try validatedLink(calendarLink)
            let tasks = try validatedLink(taskLink)
            for (key, url) in [("dashboard.calendarLink", calendar), ("dashboard.taskLink", tasks)] {
                if let url = url { preferences.set(url.absoluteString, forKey: key) }
                else { preferences.removeObject(forKey: key) }
            }
            status.stringValue = "Links saved on this Mac."
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func refreshApps() { refreshInstalledApps() }
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
        displayStatus.stringValue = "\(tvName) connected · \(mode)"
    }
}

private enum DashboardLinkError: LocalizedError {
    case invalid
    var errorDescription: String? { "Use a complete HTTPS page link without a username or password in the URL." }
}

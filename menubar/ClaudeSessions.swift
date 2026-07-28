import AppKit
import Darwin
import ServiceManagement

// MARK: - Model

struct Session {
    let id: String
    let cwd: String
    let state: String
    let message: String
    let term: String
    let pid: Int32
    let updated: Date

    var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "~" : name
    }

    /// The claude process that wrote this file. A dead pid means the session
    /// exited without firing SessionEnd (crash, kill -9, closed window).
    var isAlive: Bool {
        if pid <= 1 { return true }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    var icon: String {
        switch state {
        case "attention": return "⏸"
        case "done": return "✅"
        case "working": return "⚙️"
        default: return "💤"
        }
    }

    var detail: String {
        switch state {
        case "attention": return message.isEmpty ? "needs you" : message
        case "done": return "done"
        case "working": return "working"
        default: return "idle"
        }
    }

    /// Sort weight: what wants your attention most comes first.
    var rank: Int {
        switch state {
        case "attention": return 0
        case "done": return 1
        case "working": return 2
        default: return 3
        }
    }

    var age: String {
        let s = Int(Date().timeIntervalSince(updated))
        if s < 60 { return "\(max(s, 0))s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}

// MARK: - Appearance

/// The menu bar mark. One shape throughout, so the indicator always reads as
/// the same app; solid means a session wants you, outline means it does not.
/// Kept in one place because the exact symbol is a taste call worth changing
/// in a single edit.
enum Glyph {
    static let solid = "staroflife.fill"
    static let outline = "staroflife"
    /// Used only if the symbol is unavailable, so the indicator degrades to
    /// text rather than vanishing from the menu bar.
    static let solidFallback = "✹"
    static let outlineFallback = "✴"
}

extension NSColor {
    /// Claude's terracotta, nudged per appearance so it stays legible against
    /// both a light and a dark menu bar. This is an evocation of the brand
    /// colour, not a reproduction of Anthropic's mark.
    static let claudeTerracotta = NSColor(name: "claudeTerracotta") { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.898, green: 0.541, blue: 0.420, alpha: 1)  // #E58A6B
            : NSColor(srgbRed: 0.761, green: 0.392, blue: 0.247, alpha: 1)  // #C2643F
    }
}

// MARK: - Preferences

/// Everything the settings window writes and the app reads. Defaults live here
/// and nowhere else, so an unset key behaves the same on first launch as it
/// does after a reset.
enum Prefs {
    private static let d = UserDefaults.standard

    static var sound: Bool {
        get { d.object(forKey: "sound") as? Bool ?? true }
        set { d.set(newValue, forKey: "sound") }
    }

    static var notifyBlocked: Bool {
        get { d.object(forKey: "notifyBlocked") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifyBlocked") }
    }

    static var notifyDone: Bool {
        get { d.object(forKey: "notifyDone") as? Bool ?? true }
        set { d.set(newValue, forKey: "notifyDone") }
    }

    /// Seconds between directory scans. Clamped on read as well as on write —
    /// a stray value in the plist should not spin the CPU or freeze the UI.
    static var refreshInterval: Double {
        get { min(max(d.object(forKey: "refreshInterval") as? Double ?? 1.0, 0.5), 10.0) }
        set { d.set(min(max(newValue, 0.5), 10.0), forKey: "refreshInterval") }
    }
}

// MARK: - State directory

enum Store {
    static let dir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/session-state")

    static let header = "claude-session-state/1"

    /// Last known cwd per session. Not every hook event carries one, and a
    /// session with no cwd would otherwise lose its project name mid-flight.
    private static var cwdCache: [String: String] = [:]

    /// File layout written by session-state.sh: five header lines, then the
    /// hook's JSON payload verbatim. The hook does no parsing, so anything
    /// structured has to be pulled out here.
    static func parse(_ url: URL) -> Session? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "\n", maxSplits: 5, omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0] == header else { return nil }

        let id = url.deletingPathExtension().lastPathComponent
        var cwd = ""
        var message = ""

        if let data = String(parts[5]).data(using: .utf8),
           let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cwd = o["cwd"] as? String ?? ""
            message = o["message"] as? String ?? ""
        }

        if cwd.isEmpty {
            cwd = cwdCache[id] ?? ""
        } else {
            cwdCache[id] = cwd
        }

        return Session(
            id: id,
            cwd: cwd,
            state: String(parts[1]),
            message: message,
            term: String(parts[3]),
            pid: Int32(parts[2]) ?? 0,
            updated: Date(timeIntervalSince1970: Double(parts[4]) ?? 0)
        )
    }

    static func load() -> [Session] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []

        var sessions: [Session] = []
        for f in files {
            // Leftovers from the pre-1.0 format, and any half-written temps.
            guard f.pathExtension == "state" else {
                if f.pathExtension == "json" || f.pathExtension == "tmp" {
                    try? FileManager.default.removeItem(at: f)
                }
                continue
            }
            guard let s = parse(f) else { continue }

            // Reap orphans: dead process, or absurdly old regardless of pid.
            let age = Date().timeIntervalSince(s.updated)
            if (!s.isAlive && age > 120) || age > 12 * 3600 {
                try? FileManager.default.removeItem(at: f)
                cwdCache[s.id] = nil
                continue
            }
            sessions.append(s)
        }

        return sessions.sorted {
            $0.rank != $1.rank ? $0.rank < $1.rank : $0.updated > $1.updated
        }
    }

    static func clear(states: Set<String>) {
        for s in load() where states.contains(s.state) {
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent("\(s.id).state"))
        }
    }
}

// MARK: - Settings window

/// One plain window, built in code. There are only a handful of settings, so a
/// tabbed layout would be mostly empty space.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Called whenever a control changes, so the app can pick the value up
    /// immediately instead of waiting for the next poll.
    private let onChange: () -> Void

    private let soundCheck = NSButton(checkboxWithTitle: "Play sound on attention",
                                      target: nil, action: nil)
    private let loginCheck = NSButton(checkboxWithTitle: "Open at login",
                                      target: nil, action: nil)
    private let blockedCheck = NSButton(checkboxWithTitle: "Blocked", target: nil, action: nil)
    private let doneCheck = NSButton(checkboxWithTitle: "Finished", target: nil, action: nil)
    private let intervalField = NSTextField(string: "1.0")
    private let intervalStepper = NSStepper()

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "ClaudeSessions Settings"
        // A menu bar app has no other window to fall back on, so releasing this
        // one on close would crash the second time it is opened.
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        for c in [soundCheck, loginCheck, blockedCheck, doneCheck] {
            c.target = self
            c.action = #selector(controlChanged)
        }

        intervalField.alignment = .right
        intervalField.target = self
        intervalField.action = #selector(intervalFieldChanged)
        intervalField.translatesAutoresizingMaskIntoConstraints = false
        intervalField.widthAnchor.constraint(equalToConstant: 52).isActive = true

        intervalStepper.minValue = 0.5
        intervalStepper.maxValue = 10.0
        intervalStepper.increment = 0.5
        intervalStepper.valueWraps = false
        intervalStepper.target = self
        intervalStepper.action = #selector(intervalStepperChanged)

        let intervalRow = NSStackView(views: [
            label("Refresh interval"), intervalField, intervalStepper, label("seconds"),
        ])
        intervalRow.orientation = .horizontal
        intervalRow.spacing = 6

        let notifyRow = NSStackView(views: [label("Notify on"), blockedCheck, doneCheck])
        notifyRow.orientation = .horizontal
        notifyRow.spacing = 10

        let clearButton = NSButton(title: "Clear finished sessions",
                                   target: self, action: #selector(clearFinished))
        clearButton.bezelStyle = .rounded

        let stack = NSStackView(views: [
            soundCheck,
            loginCheck,
            separator(),
            intervalRow,
            notifyRow,
            separator(),
            clearButton,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.textColor = .labelColor
        return l
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 330).isActive = true
        return box
    }

    /// Pull current values in every time the window is shown. The login item
    /// state in particular can change outside this app, via System Settings.
    func reload() {
        soundCheck.state = Prefs.sound ? .on : .off
        loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
        blockedCheck.state = Prefs.notifyBlocked ? .on : .off
        doneCheck.state = Prefs.notifyDone ? .on : .off
        intervalField.stringValue = String(format: "%.1f", Prefs.refreshInterval)
        intervalStepper.doubleValue = Prefs.refreshInterval
    }

    func show() {
        reload()
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Actions

    @objc private func controlChanged(_ sender: NSButton) {
        switch sender {
        case soundCheck: Prefs.sound = sender.state == .on
        case blockedCheck: Prefs.notifyBlocked = sender.state == .on
        case doneCheck: Prefs.notifyDone = sender.state == .on
        case loginCheck: toggleLogin(on: sender.state == .on)
        default: break
        }
        onChange()
    }

    private func toggleLogin(on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("login item toggle failed: \(error)")
            // Snap back, so the checkbox never claims something that did not happen.
            loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func intervalFieldChanged() {
        Prefs.refreshInterval = intervalField.doubleValue
        reload()
        onChange()
    }

    @objc private func intervalStepperChanged() {
        Prefs.refreshInterval = intervalStepper.doubleValue
        reload()
        onChange()
    }

    @objc private func clearFinished() {
        Store.clear(states: ["done", "idle", "start"])
        onChange()
    }
}

// MARK: - App

@main
struct Main {
    static func main() {
        // `ClaudeSessions --dump` prints what the app currently sees and exits.
        // The menu bar is hard to inspect; this is how you debug parsing.
        if CommandLine.arguments.contains("--dump") {
            let sessions = Store.load()
            if sessions.isEmpty { print("(no sessions)") }
            for s in sessions {
                print("\(s.state)\t\(s.project)\tpid=\(s.pid)\tterm=\(s.term)\t"
                    + "age=\(s.age)\tmsg=\(s.message.isEmpty ? "-" : s.message)")
            }
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var sessions: [Session] = []
    private var settings: SettingsWindowController?
    /// Sessions already announced, so the sound fires on transition only.
    private var announced: Set<String> = []

    func applicationDidFinishLaunching(_: Notification) {
        try? FileManager.default.createDirectory(
            at: Store.dir, withIntermediateDirectories: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        refresh()
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Prefs.refreshInterval, repeats: true) {
            [weak self] _ in self?.refresh()
        }
    }

    // MARK: Status bar

    /// A symbol image has its colour baked in at render time, so a dynamic
    /// colour cannot re-resolve itself later the way live-drawn text can.
    /// Resolve it against the menu bar's own appearance instead of the app's —
    /// the menu bar can be dark while the rest of the system is light.
    ///
    /// No appearance observer is needed: `refresh()` rebuilds the image on
    /// every tick, so a light/dark switch corrects itself within one interval.
    private func resolve(_ color: NSColor) -> NSColor {
        var out = color
        let appearance = statusItem?.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    /// SF Symbol tinted to a fixed colour. Template rendering has to be off,
    /// otherwise the system repaints it to match the menu bar and every state
    /// collapses to the same shade.
    private func symbol(_ name: String, _ color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = base.withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }

    private func refresh() {
        sessions = Store.load()

        let attention = sessions.filter { $0.state == "attention" }
        let done = sessions.filter { $0.state == "done" }
        let working = sessions.filter { $0.state == "working" }

        // Solid burst when a session wants you, outline when none does.
        // Colours avoid green on purpose: macOS already uses a green dot in the
        // menu bar for "camera is on", and a second green dot beside it reads
        // as a system warning rather than as this app.
        let (name, fallback, count, color): (String, String, Int, NSColor) = {
            if !attention.isEmpty {
                return (Glyph.solid, Glyph.solidFallback, attention.count, .claudeTerracotta)
            }
            if !done.isEmpty {
                return (Glyph.solid, Glyph.solidFallback, done.count, .systemBlue)
            }
            // Full-contrast label colour, not secondary: a working session is
            // ordinary but still needs to be readable at a glance.
            if !working.isEmpty {
                return (Glyph.outline, Glyph.outlineFallback, working.count, .labelColor)
            }
            return (Glyph.outline, Glyph.outlineFallback, 0, .tertiaryLabelColor)
        }()

        guard let button = statusItem.button else { return }
        let shown = resolve(color)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

        if let image = symbol(name, shown) {
            button.image = image
            button.attributedTitle = NSAttributedString(
                string: count > 0 ? " \(count)" : "",
                attributes: [.foregroundColor: shown, .font: font])
        } else {
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: count > 0 ? "\(fallback) \(count)" : fallback,
                attributes: [.foregroundColor: shown, .font: font])
        }

        chime(for: attention + done)
    }

    /// Ping once when a session newly starts waiting on you, and only for the
    /// states the user asked to hear about.
    private func chime(for waiting: [Session]) {
        let ids = Set(waiting.map { "\($0.id):\($0.state)" })
        let fresh = ids.subtracting(announced)
        let audible = fresh.contains { id in
            if id.hasSuffix(":attention") { return Prefs.notifyBlocked }
            if id.hasSuffix(":done") { return Prefs.notifyDone }
            return false
        }
        if audible, !announced.isEmpty, Prefs.sound {
            NSSound(named: "Submarine")?.play()
        }
        announced = ids
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No active Claude sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for s in sessions {
                let item = NSMenuItem(title: "", action: #selector(focusSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = s.id
                item.attributedTitle = row(for: s)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func row(for s: Session) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(
            string: "\(s.icon)  \(s.project)   ",
            attributes: [.font: NSFont.menuFont(ofSize: 13)]))

        var detail = s.detail
        if detail.count > 48 { detail = String(detail.prefix(47)) + "…" }
        out.append(NSAttributedString(
            string: "\(detail) · \(s.age)",
            attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: s.state == "attention" ? NSColor.systemRed : NSColor.secondaryLabelColor,
            ]))
        return out
    }

    // MARK: Actions

    @objc private func openSettings() {
        if settings == nil {
            settings = SettingsWindowController(onChange: { [weak self] in
                self?.restartTimer()
                self?.refresh()
            })
        }
        settings?.show()
    }

    /// Bring the terminal that hosts this session to the front. Ghostty exposes
    /// no per-window scripting, so this lands you in the right app, not the
    /// right tab. Falls back to revealing the project folder.
    @objc private func focusSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let s = sessions.first(where: { $0.id == id }) else { return }

        let appName: String? = {
            switch s.term {
            case "ghostty": return "Ghostty"
            case "iTerm.app": return "iTerm"
            case "Apple_Terminal": return "Terminal"
            case "WezTerm": return "WezTerm"
            case "vscode": return "Visual Studio Code"
            case "kitty": return "kitty"
            default: return nil
            }
        }()

        if let appName,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID(for: appName))
            ?? appURL(named: appName) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if !s.cwd.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.cwd)])
        }
    }

    private func bundleID(for name: String) -> String {
        switch name {
        case "Ghostty": return "com.mitchellh.ghostty"
        case "iTerm": return "com.googlecode.iterm2"
        case "Terminal": return "com.apple.Terminal"
        case "WezTerm": return "com.github.wez.wezterm"
        case "Visual Studio Code": return "com.microsoft.VSCode"
        case "kitty": return "net.kovidgoyal.kitty"
        default: return ""
        }
    }

    private func appURL(named name: String) -> URL? {
        let path = "/Applications/\(name).app"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

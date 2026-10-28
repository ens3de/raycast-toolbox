// open-passwords-menu — opens the Passwords menu bar window.
//
// Run from Raycast ("打开密码菜单"). Clicks the Passwords menu bar icon
// (com.apple.Passwords.MenuBarExtra) where Accessibility reports it and puts
// the pointer back. When it was last run more than `resetAfter` ago, the
// window is taken back to its first page if it reopened on an inner one
// (a password's details, say); a recent run leaves it where it was. While the
// window stays open, ⌘1…⌘9 open that row of the list on show, Return in the
// search field opens the first, on a password's page ⌘1/⌘2/⌘3 copy the user
// name, password and verification code and hide the window, and Esc goes back
// a page.
//
// Build: ./build.sh (open-passwords-menu.sh, one level up, runs the result)
// Needs Accessibility access for whatever runs it (Raycast).

import AppKit
import ApplicationServices

let bundleID = "com.apple.Passwords.MenuBarExtra"

/// After this long without a run, the window opens on its first page again.
let resetAfter: TimeInterval = 5 * 60

/// When the command last ran (a timestamp only), kept between runs.
let lastRunURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Caches/open-passwords-menu.last-run")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: - Accessibility helpers

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
}

func size(_ element: AXUIElement) -> CGSize? {
    guard let value = attribute(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
}

/// Several attributes in one round trip; a missing one comes back as an
/// error value, which the casts at the call site treat as nil.
func attributes(_ element: AXUIElement, _ names: [String]) -> [AnyObject] {
    var values: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &values) == .success else { return [] }
    return values as [AnyObject]? ?? []
}

/// Polls `probe` every 10 ms until it returns a value or `timeout` passes.
func waitFor<T>(_ timeout: TimeInterval, _ probe: () -> T?) -> T? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let value = probe() { return value }
        usleep(10_000)
    } while Date() < deadline
    return nil
}

// MARK: - Last run

/// Seconds since the previous run (nil for the first one), and records this
/// run as the latest.
func secondsSinceLastRun() -> TimeInterval? {
    let now = Date()
    let previous = (try? String(contentsOf: lastRunURL, encoding: .utf8))
        .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .map { now.timeIntervalSince1970 - $0 }
    try? String(now.timeIntervalSince1970).write(to: lastRunURL, atomically: true, encoding: .utf8)
    return previous
}

// MARK: - Opening the menu

/// Clicks at `target` and puts the pointer back where it was.
func click(at target: CGPoint) {
    let source = CGEventSource(stateID: .hidSystemState)
    let original = CGEvent(source: nil)?.location ?? target
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: .left)
        event?.flags = []
        event?.post(tap: .cghidEventTap)
    }
    usleep(10_000)
    CGWarpMouseCursorPosition(original)
    CGAssociateMouseAndMouseCursorPosition(1)
}

/// The middle of the Passwords menu bar icon; clicking it opens or closes the window.
func menuBarIcon(_ app: AXUIElement) -> CGPoint? {
    let extrasBar = attribute(app, "AXExtrasMenuBar").flatMap {
        CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
    }
    guard let extrasBar, let item = children(extrasBar).first,
          let origin = point(item, kAXPositionAttribute), let size = size(item) else { return nil }
    return CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
}

// MARK: - Back to the first page

/// The back button's name: "返回" on a Chinese system.
let backNames: Set<String> = ["返回", "Back", "後退"]

/// The page on show. The window's content sits one group deep: the back
/// button (on inner pages only), the "show all passwords" button and the
/// page's list, whose description names the page. One request per element.
struct Page {
    let back: AXUIElement?
    let signature: [String]
}

func currentPage(_ window: AXUIElement) -> Page {
    var back: AXUIElement?
    var signature: [String] = []
    for group in children(window) {
        for element in children(group) {
            let values = attributes(element, [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute])
            let role = values.first as? String ?? ""
            let names = values.dropFirst().compactMap { $0 as? String }
            signature.append(([role] + names).joined(separator: "|"))
            if role == kAXButtonRole as String, names.contains(where: backNames.contains) {
                back = element
            }
        }
    }
    return Page(back: back, signature: signature)
}

/// Presses back until the first page (no back button) shows. The window
/// reopens on the page it was left on, so a back button is there within a few
/// frames; each press waits only until the page has changed.
func goToFirstPage(_ window: AXUIElement) {
    var page = waitFor(0.3) { () -> Page? in
        let page = currentPage(window)
        return page.back == nil ? nil : page
    }
    var presses = 0
    while let shown = page, let back = shown.back, presses < 8 {
        AXUIElementPerformAction(back, kAXPressAction as CFString)
        presses += 1
        page = waitFor(0.5) { () -> Page? in
            let next = currentPage(window)
            return next.signature == shown.signature ? nil : next
        }
    }
    if presses > 0 { focusSearchField(window) }
}

/// Back on the first page, typing goes to the search field again.
func focusSearchField(_ window: AXUIElement) {
    if let field = waitFor(0.3, { searchField(in: window) }) {
        AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
}

/// The first page's search field, a few levels into the window.
func searchField(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    let role = attribute(element, kAXRoleAttribute) as? String
    if role == kAXTextFieldRole as String || role == "AXSearchField" { return element }
    guard depth < 5 else { return nil }
    for child in children(element) {
        if let field = searchField(in: child, depth: depth + 1) { return field }
    }
    return nil
}

// MARK: - Keys while the window is open

/// Key codes of 1…9 on the number row, in order.
let digitKeyCodes: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

/// The list's rows on show, top to bottom: those the scroll area does not clip.
func visibleRows(in window: AXUIElement) -> [CGRect] {
    func find(_ element: AXUIElement, _ role: String, depth: Int = 0) -> AXUIElement? {
        if attribute(element, kAXRoleAttribute) as? String == role { return element }
        guard depth < 6 else { return nil }
        return children(element).lazy.compactMap { find($0, role, depth: depth + 1) }.first
    }
    func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element, kAXPositionAttribute), let size = size(element) else { return nil }
        return CGRect(origin: origin, size: size)
    }
    guard let outline = find(window, kAXOutlineRole as String),
          let clip = attribute(outline, kAXParentAttribute).flatMap({ frame($0 as! AXUIElement) }) else { return [] }
    let rows = attribute(outline, kAXRowsAttribute) as? [AXUIElement] ?? []
    return rows.compactMap(frame)
        .filter { clip.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        .sorted { $0.minY < $1.minY }
}

/// On a password's page: where its user name, password and verification code
/// are shown, in that order (nil where the page has none). Clicking one copies
/// it. Each row is a label on the left and its
/// value against the right edge; only the labels' text is looked at.
func detailFields(in window: AXUIElement) -> [CGRect?] {
    let userNames: Set<String> = ["用户名", "User Name", "Username", "使用者名稱"]
    let passwords: Set<String> = ["密码", "Password", "密碼"]
    let codes: Set<String> = ["验证码", "Verification Code", "驗證碼"]
    func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = point(element, kAXPositionAttribute), let size = size(element) else { return nil }
        return CGRect(origin: origin, size: size)
    }
    guard let content = children(window).first.flatMap({ group in
              children(group).first { attribute($0, kAXRoleAttribute) as? String == kAXScrollAreaRole as String }
          }).flatMap({ children($0).first }),
          let bounds = frame(content) else { return [nil, nil, nil] }
    let texts = children(content).filter { attribute($0, kAXRoleAttribute) as? String == kAXStaticTextRole as String }
        .compactMap { element in frame(element).map { (element, $0) } }
    let labels = texts.filter { $0.1.minX < bounds.minX + 20 }
    let values = texts.filter { $0.1.maxX > bounds.maxX - 20 }.map(\.1)
    func value(labelled names: Set<String>) -> CGRect? {
        guard let label = labels.first(where: { names.contains(attribute($0.0, kAXValueAttribute) as? String ?? "") }) else { return nil }
        return values.first { abs($0.midY - label.1.midY) < 6 }
    }
    let named = [value(labelled: userNames), value(labelled: passwords), value(labelled: codes)]
    // Labels in an unexpected language: the first two rows are user name and
    // password. (No guess for the code: the third row is often the website.)
    guard named.allSatisfy({ $0 == nil }) else { return named }
    let ordered = values.sorted { $0.minY < $1.minY }
    return [ordered.first, ordered.dropFirst().first, nil]
}

/// Runs while the window is open (Raycast starts it detached, see `startKeyWatcher`):
/// ⌘1…⌘9 click that row of the list, the same as clicking it (Return in the
/// search field clicks the first); on a password's page ⌘1, ⌘2 and ⌘3 copy its
/// user name, password and verification code, by clicking them, and hide the
/// window. Esc on an
/// inner page goes back one page (on the first page it is left to close the
/// window, as usual). Other keys pass through untouched, and nothing typed is
/// read or kept.
func watchKeys(_ app: AXUIElement) -> Never {
    // One watcher at a time: a second one (the window reopened quickly) leaves.
    let lock = open(lastRunURL.path + ".lock", O_CREAT | O_RDWR, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
    // Esc is decided inside the tap, which must answer quickly.
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
    AXUIElementSetMessagingTimeout(app, 0.25)

    let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = keyTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let modifiers = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 53, modifiers.isEmpty {
            // Decided here and now: the window must not see an Esc meant as "back".
            guard let window = (attribute(watchedApp!, kAXWindowsAttribute) as? [AXUIElement])?.first else {
                return Unmanaged.passUnretained(event)
            }
            let page = currentPage(window)
            guard let back = page.back else { return Unmanaged.passUnretained(event) }
            AXUIElementPerformAction(back, kAXPressAction as CFString)
            DispatchQueue.main.async {
                let next = waitFor(0.5) { () -> Page? in
                    let next = currentPage(window)
                    return next.signature == page.signature ? nil : next
                }
                if let next, next.back == nil { focusSearchField(window) }
            }
            return nil
        }
        if keyCode == 36 || keyCode == 76, modifiers.isEmpty {
            // Return in the search field opens the first row.
            guard let window = (attribute(watchedApp!, kAXWindowsAttribute) as? [AXUIElement])?.first,
                  let field = searchField(in: window),
                  attribute(field, kAXFocusedAttribute) as? Bool == true,
                  let first = visibleRows(in: window).first else {
                return Unmanaged.passUnretained(event)
            }
            DispatchQueue.main.async { click(at: CGPoint(x: first.midX, y: first.midY)) }
            return nil
        }
        guard modifiers == .maskCommand,
              let index = digitKeyCodes.firstIndex(of: keyCode) else {
            return Unmanaged.passUnretained(event)
        }
        DispatchQueue.main.async {
            guard let window = (attribute(watchedApp!, kAXWindowsAttribute) as? [AXUIElement])?.first else { return }
            let rows = visibleRows(in: window)
            let fields = rows.isEmpty ? detailFields(in: window) : []
            if index < rows.count {
                click(at: CGPoint(x: rows[index].midX, y: rows[index].midY))
            } else if index < fields.count, let field = fields[index] {
                // Copied: hide the window (it reopens on this page) so the
                // field being filled in is back in front.
                // The window handles the clicks in order, so the copy is done
                // before it closes; no need to wait in between.
                let icon = menuBarIcon(watchedApp!)
                click(at: CGPoint(x: field.midX, y: field.midY))
                if let icon { click(at: icon) }
            }
        }
        return nil
    }
    watchedApp = app
    let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                            callback: callback, userInfo: nil)
    guard let tap else { exit(1) }
    keyTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    // Gone with the window; an hour at most either way.
    let started = Date()
    Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
        let open = !((attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).isEmpty
        if !open || Date().timeIntervalSince(started) > 3600 { exit(0) }
    }
    RunLoop.main.run()
    exit(0)
}

nonisolated(unsafe) var keyTap: CFMachPort?
nonisolated(unsafe) var watchedApp: AXUIElement?

/// Starts this program again as the key watcher, in its own session with no
/// output, so it outlives this run and Raycast does not wait for it.
func startKeyWatcher() {
    guard let path = Bundle.main.executablePath else { return }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    var files: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&files)
    for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&files, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
    var pid: pid_t = 0
    let argv = [path, "--keys"].map { strdup($0) } + [nil]
    posix_spawn(&pid, path, &files, &attributes, argv, environ)
    argv.forEach { free($0) }
    posix_spawn_file_actions_destroy(&files)
    posix_spawnattr_destroy(&attributes)
}

// MARK: - Main

guard AXIsProcessTrusted() else { fail("Accessibility access is needed (System Settings → Privacy & Security → Accessibility).") }
guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else {
    fail("The Passwords menu bar app is not running.")
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 1.5)

if CommandLine.arguments.dropFirst().first == "--keys" { watchKeys(app) }

let idle = secondsSinceLastRun()
guard let icon = menuBarIcon(app) else { fail("The Passwords menu bar icon was not found.") }
// With the window already open, the click closes it and there is nothing more to do.
let wasOpen = !((attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).isEmpty
click(at: icon)
guard !wasOpen, let window = waitFor(1.5, { (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first }) else { exit(0) }
startKeyWatcher()

// Long unused: start over on the first page. Recently used: leave it be.
if (idle ?? .infinity) > resetAfter {
    goToFirstPage(window)
}

// open-passwords-menu — opens the Passwords menu bar window.
//
// Run from Raycast ("打开密码菜单"). When the front app is Ardia, it first
// sends ⌘⇧\ (Command, Shift, and the backslash key) — the shortcut the user
// binds to "Activate the extension" for iCloud Passwords. If that popup
// appears, it stops: a pairing PIN is left alone, and the picker is left to
// the extension's own keys. If the popup does not appear, it clicks a pinned
// toolbar button when exactly one can be found. If that also fails, it uses
// the menu bar.
//
// Otherwise it clicks the Passwords menu bar icon
// (com.apple.Passwords.MenuBarExtra) where Accessibility reports it and puts
// the pointer back. When it was last run more than `resetAfter` ago, the
// window is taken back to its first page if it reopened on an inner one
// (a password's details, say); a recent run leaves it where it was. While the
// window stays open, ⌘1…⌘9 open that row of the list on show, Return in the
// search field opens the first, on a password's page ⌘1/⌘2/⌘3 copy the user
// name, password and verification code and hide the window, and Esc goes back
// a page. Those shortcuts stay on the menu bar window; they are not sent to
// the extension popup.
//
// When the front app is a browser, the menu bar window opens on its first page
// with the current site's domain typed into the search field, and Return opens
// the first match. Safari and Chromium browsers (including Ardia) are asked
// through AppleScript, Firefox through its address bar.
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

// MARK: - The browser's current site

/// Ardia. Chromium, so the current tab is read the same way as the others.
let ardiaBundleID = "com.ardia.browser"

/// How to read the current page's address, by browser bundle ID.
let chromiumBrowsers: Set<String> = [
    "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
    "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
    "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium", "com.citrolabs.ego.lite",
    ardiaBundleID,
]

func runAppleScript(_ source: String, timeout: TimeInterval = 1.0) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline { usleep(10_000) }
    if process.isRunning { process.terminate(); return nil }
    guard process.terminationStatus == 0 else { return nil }
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

/// Firefox has no AppleScript for tabs; its address bar is read instead.
func firefoxAddress(pid: pid_t) -> String? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    func find(_ element: AXUIElement, depth: Int = 0) -> String? {
        if attribute(element, "AXDOMIdentifier") as? String == "urlbar-input",
           let value = attribute(element, kAXValueAttribute) as? String { return value }
        guard depth < 10 else { return nil }
        for child in children(element) { if let found = find(child, depth: depth + 1) { return found } }
        return nil
    }
    guard let window = attribute(app, kAXFocusedWindowAttribute) as? AXUIElement else { return nil }
    return find(window)
}

/// The site's host from an address, without "www."; nil for pages that are
/// not a website (new tab, settings, local files) or a local or private address.
func domain(fromAddress address: String) -> String? {
    var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.contains("://") { text = "https://" + text }
    guard let components = URLComponents(string: text),
          let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
          var host = components.host?.lowercased(), host.contains(".") else { return nil }
    if host.hasPrefix("www.") { host.removeFirst(4) }
    guard host.contains("."), !isLocalOrPrivateHost(host) else { return nil }
    return host
}

/// localhost, mDNS `.local` names, and loopback or private IPv4.
func isLocalOrPrivateHost(_ host: String) -> Bool {
    if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
    let parts = host.split(separator: ".")
    guard parts.count == 4, parts.allSatisfy({ part in
        !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber }
    }) else { return false }
    let numbers = parts.compactMap { Int($0) }
    guard numbers.count == 4, numbers.allSatisfy({ (0...255).contains($0) }) else { return false }
    let a = numbers[0], b = numbers[1]
    return a == 0 || a == 10 || a == 127
        || (a == 169 && b == 254)
        || (a == 172 && (16...31).contains(b))
        || (a == 192 && b == 168)
}

/// The front app, once Raycast (which just launched this) has stepped aside.
func frontApplication() -> NSRunningApplication? {
    let raycast = "com.raycast.macos"
    return waitFor(0.5) { () -> NSRunningApplication? in
        let app = NSWorkspace.shared.frontmostApplication
        return app?.bundleIdentifier == raycast ? nil : app
    } ?? NSWorkspace.shared.frontmostApplication
}

/// The current page's address in `application`, when it is a browser we know.
func browserAddress(of application: NSRunningApplication) -> String? {
    guard let id = application.bundleIdentifier else { return nil }
    if id == "com.apple.Safari" || id == "com.apple.SafariTechnologyPreview" {
        return runAppleScript("tell application id \"\(id)\" to return URL of front document")
    }
    if chromiumBrowsers.contains(id) {
        return runAppleScript("tell application id \"\(id)\" to return URL of active tab of front window")
    }
    if id == "org.mozilla.firefox" || id == "org.mozilla.firefoxdeveloperedition" {
        return firefoxAddress(pid: application.processIdentifier)
    }
    return nil
}

/// The domain of the page open in the front browser, if the front app is one.
func frontBrowserDomain() -> String? {
    guard let front = frontApplication() else { return nil }
    return browserAddress(of: front).flatMap(domain(fromAddress:))
}

/// Types `text` into whatever has the keyboard focus, as key events.
func type(_ text: String) {
    let source = CGEventSource(stateID: .hidSystemState)
    for unit in text.utf16 {
        var character = unit
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.flags = []
            event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &character)
            event?.post(tap: .cghidEventTap)
        }
        usleep(2_000)
    }
}

/// Return (not keypad enter). The key watcher turns it into a click on the first row.
func pressReturn() {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: down)
        event?.flags = []
        event?.post(tap: .cghidEventTap)
        usleep(8_000)
    }
}

/// Puts `text` in the first page's search field, replacing what was there,
/// then presses Return so the first match opens.
func search(for text: String, in window: AXUIElement) {
    guard let field = waitFor(0.5, { searchField(in: window) }) else { return }
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "" as CFString)
    usleep(30_000)
    type(text)
    // The list filters as the letters arrive; Return too early opens the old first row.
    usleep(400_000)
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    pressReturn()
}

// MARK: - iCloud Passwords in Ardia

/// Chrome Web Store id of Apple's iCloud Passwords extension.
let iCloudPasswordsExtensionID = "pejdijmoenmkgeppbflobdenhhabjlaj"

/// ANSI backslash (`kVK_ANSI_Backslash`). Command and Shift are held as well,
/// which is the combo Chrome records as ⌘⇧\. Not a "|" character by itself.
/// The user binds it in Ardia; this script only sends it.
let extensionShortcutKeyCode: CGKeyCode = 0x2A

/// How long to wait for the extension popup after the shortcut or the toolbar click.
let extensionPopupTimeout: TimeInterval = 0.8

/// Popup titles. A window matches when its title is one of these, or that
/// name plus a separator. Accounts, passwords, codes, and list rows are not read.
let extensionPopupTitles: Set<String> = [
    "iCloud Passwords",
    "iCloud 密码",
    "iCloud 密碼",
]

func axWindows(_ app: AXUIElement) -> [AXUIElement] {
    attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
}

func sameElement(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
    CFEqual(a, b)
}

/// ⌘⇧\ to the front app: the backslash key with Command and Shift down.
func sendCommandShiftBackslash() {
    let source = CGEventSource(stateID: .hidSystemState)
    let flags: CGEventFlags = [.maskCommand, .maskShift]
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: extensionShortcutKeyCode, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        usleep(12_000)
    }
}

func isPopupRole(_ window: AXUIElement) -> Bool {
    let role = attribute(window, kAXRoleAttribute) as? String ?? ""
    return role == kAXWindowRole as String || role == kAXSheetRole as String || role == kAXDialogRole as String
}

func windowTitle(_ window: AXUIElement) -> String {
    (attribute(window, kAXTitleAttribute) as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func isPopupSized(_ window: AXUIElement) -> Bool {
    guard isPopupRole(window), let frame = size(window) else { return false }
    return frame.width >= 140 && frame.width <= 520 && frame.height >= 80 && frame.height <= 720
}

func titleMatchesExtension(_ title: String) -> Bool {
    extensionPopupTitles.contains { name in
        title == name
            || title.hasPrefix(name + " ")
            || title.hasPrefix(name + "—")
            || title.hasPrefix(name + " —")
            || title.hasPrefix(name + " - ")
    }
}

/// Title and role, or a popup-sized window whose document is this extension's
/// own page (`extension://` plus the id). A normal tab is too big to match,
/// and the document URL is not logged.
func isNamedExtensionPopup(_ window: AXUIElement) -> Bool {
    guard isPopupSized(window) else { return false }
    if titleMatchesExtension(windowTitle(window)) { return true }
    if let document = attribute(window, kAXDocumentAttribute) as? String,
       document.contains("extension://\(iCloudPasswordsExtensionID)") {
        return true
    }
    return false
}

/// A window that showed up since `before`. A matching title wins. An untitled
/// popup-sized window counts only when it is the only new one, so a download
/// panel or a second window does not look like success.
func appearedExtensionPopup(of app: AXUIElement, since before: [AXUIElement]) -> AXUIElement? {
    let fresh = axWindows(app).filter { window in !before.contains { sameElement($0, window) } }
    if let named = fresh.first(where: isNamedExtensionPopup) { return named }
    guard fresh.count == 1, let only = fresh.first, isPopupSized(only), windowTitle(only).isEmpty else { return nil }
    return only
}

func isPasswordsExtensionButton(_ element: AXUIElement) -> Bool {
    if let identifier = attribute(element, kAXIdentifierAttribute) as? String,
       identifier.contains(iCloudPasswordsExtensionID) {
        return true
    }
    let values = attributes(element, [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute])
    for case let raw as String in values {
        let line = String(raw.prefix { !$0.isNewline }).trimmingCharacters(in: .whitespacesAndNewlines)
        if extensionPopupTitles.contains(line) { return true }
    }
    return false
}

func findElement(_ element: AXUIElement, role: String, depth: Int = 0, limit: Int) -> AXUIElement? {
    if attribute(element, kAXRoleAttribute) as? String == role { return element }
    guard depth < limit else { return nil }
    for child in children(element) {
        if let found = findElement(child, role: role, depth: depth + 1, limit: limit) { return found }
    }
    return nil
}

/// Buttons whose name is the extension. A second match makes the result
/// ambiguous, and the walk stops.
func extensionButtons(in element: AXUIElement, depth: Int = 0, limit: Int) -> [AXUIElement] {
    var matches: [AXUIElement] = []
    func walk(_ element: AXUIElement, depth: Int) {
        if matches.count > 1 || depth > limit { return }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        if role == kAXButtonRole as String || role == kAXPopUpButtonRole as String || role == kAXMenuButtonRole as String {
            if isPasswordsExtensionButton(element) { matches.append(element) }
        }
        for child in children(element) { walk(child, depth: depth + 1) }
    }
    walk(element, depth)
    return matches
}

/// The pinned iCloud Passwords toolbar button, only when the toolbar has exactly one.
/// No toolbar, or more than one match: nothing to click.
func pinnedPasswordsButton(in window: AXUIElement) -> AXUIElement? {
    guard let toolbar = findElement(window, role: kAXToolbarRole as String, limit: 6) else { return nil }
    let matches = extensionButtons(in: toolbar, limit: 8)
    return matches.count == 1 ? matches[0] : nil
}

func clickElement(_ element: AXUIElement) {
    if let origin = point(element, kAXPositionAttribute), let frame = size(element), frame.width > 0, frame.height > 0 {
        click(at: CGPoint(x: origin.x + frame.width / 2, y: origin.y + frame.height / 2))
    } else {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }
}

func frontWindow(_ app: AXUIElement) -> AXUIElement? {
    if let focused = attribute(app, kAXFocusedWindowAttribute) as? AXUIElement { return focused }
    return axWindows(app).first
}

/// "123456", "123 456", or "123-456". The characters are not kept.
func isPINToken(_ token: String) -> Bool {
    guard !token.isEmpty, token.count <= 8 else { return false }
    var digits = 0
    for character in token {
        if character.isASCII, let byte = character.asciiValue, byte >= 48, byte <= 57 {
            digits += 1
        } else if character == "-" || character.isWhitespace {
            continue
        } else {
            return false
        }
    }
    return digits == 6
}

/// The pairing screen shows a 6-digit PIN (one text, or six single digits).
/// Lists are not walked, so account rows are never read. The digits are only
/// tested as a pattern and are not stored or logged.
func isPairingPINPage(_ window: AXUIElement) -> Bool {
    var sixDigitText = false
    var singleDigits = 0
    func walk(_ element: AXUIElement, depth: Int) {
        if sixDigitText || singleDigits >= 6 || depth > 9 { return }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        if role == kAXListRole as String || role == kAXOutlineRole as String
            || role == kAXTableRole as String || role == kAXRowRole as String {
            return
        }
        if role == kAXStaticTextRole as String, let raw = attribute(element, kAXValueAttribute) as? String {
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Longer than a PIN (a name, a sentence): not inspected.
            if token.count <= 8 {
                if isPINToken(token) {
                    sixDigitText = true
                    return
                }
                if token.count == 1, let byte = token.utf8.first, byte >= 48, byte <= 57 {
                    singleDigits += 1
                }
            }
        }
        for child in children(element) { walk(child, depth: depth + 1) }
    }
    walk(window, 0)
    return sixDigitText || singleDigits >= 6
}

/// Popup is open. Phase 1 stops: a pairing PIN is left for the user (no
/// Return, no chosen item), and the picker is left to the extension's own
/// Up/Down/Enter. Menu-bar shortcuts are not replayed here.
func leaveExtensionPopup(_ popup: AXUIElement) {
    if isPairingPINPage(popup) { return }
}

/// Opens the iCloud Passwords popup in Ardia. False means use the menu bar.
func openICloudPasswordsExtension(_ application: NSRunningApplication) -> Bool {
    // macOS 14 and later only honors activation that names the app in front.
    if !application.isActive, let front = NSWorkspace.shared.frontmostApplication,
       front.processIdentifier != application.processIdentifier {
        _ = application.activate(from: front)
        _ = waitFor(0.3) { application.isActive ? true : nil }
    }
    let browser = AXUIElementCreateApplication(application.processIdentifier)
    AXUIElementSetMessagingTimeout(browser, 0.4)
    let beforeShortcut = axWindows(browser)
    sendCommandShiftBackslash()
    if let popup = waitFor(extensionPopupTimeout, { appearedExtensionPopup(of: browser, since: beforeShortcut) }) {
        leaveExtensionPopup(popup)
        return true
    }
    if let window = frontWindow(browser), let button = pinnedPasswordsButton(in: window) {
        let beforeClick = axWindows(browser)
        clickElement(button)
        if let popup = waitFor(extensionPopupTimeout, { appearedExtensionPopup(of: browser, since: beforeClick) }) {
            leaveExtensionPopup(popup)
            return true
        }
    }
    return false
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

let command = CommandLine.arguments.dropFirst().first
if command == "--domain" {
    print(frontBrowserDomain() ?? "(none)")
    exit(0)
}

let passwordsPID = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
if command == "--keys" {
    guard let passwordsPID else { fail("The Passwords menu bar app is not running.") }
    let app = AXUIElementCreateApplication(passwordsPID)
    AXUIElementSetMessagingTimeout(app, 1.5)
    watchKeys(app)
}

let front = frontApplication()
// Ardia: the extension popup first. The menu bar, including this tab's domain,
// runs only when that popup never appears. The menu bar app is not required
// for the extension itself.
if let front, front.bundleIdentifier == ardiaBundleID, openICloudPasswordsExtension(front) {
    exit(0)
}

guard let passwordsPID else { fail("The Passwords menu bar app is not running.") }
let app = AXUIElementCreateApplication(passwordsPID)
AXUIElementSetMessagingTimeout(app, 1.5)

let idle = secondsSinceLastRun()
// The browser's site is read before the click, while that browser is in front.
let siteDomain = front.flatMap { browserAddress(of: $0) }.flatMap(domain(fromAddress:))
guard let icon = menuBarIcon(app) else { fail("The Passwords menu bar icon was not found.") }
// With the window already open, the click closes it and there is nothing more to do.
let wasOpen = !((attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []).isEmpty
click(at: icon)
guard !wasOpen, let window = waitFor(1.5, { (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first }) else { exit(0) }
startKeyWatcher()

if let siteDomain {
    // In a browser: first page, searched for this site.
    goToFirstPage(window)
    search(for: siteDomain, in: window)
} else if (idle ?? .infinity) > resetAfter {
    // Long unused: start over on the first page. Recently used: leave it be.
    goToFirstPage(window)
}

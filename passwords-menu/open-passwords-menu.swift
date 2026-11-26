// open-passwords-menu — opens the Passwords menu bar window.
//
// Run from Raycast ("打开密码菜单"). When the front app is Ardia, it activates
// Ardia and sends ⌘⇧\ (Command, Shift, and the backslash key) — the shortcut
// the user binds to "Activate the extension" for iCloud Passwords — then
// stops. It does not also click the toolbar button (that button toggles) or
// the Passwords menu bar in the same run. A detached watcher then handles the
// picker. Unmodified Enter fills the first row (a click when the row can be
// seen, otherwise ArrowDown and then Enter). After Up or Down, Enter is left
// alone and fills the highlighted row. The picker is often not a new window
// of Ardia's own process, so Enter is not gated on that. Nothing is filled
// until the user presses Enter. A pairing PIN page is not clicked and is not
// sent keys. Row text is never read.
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
// When the front app is another browser, the menu bar window opens on its first
// page with the current site's domain typed into the search field, and Return
// opens the first match. Safari and Chromium browsers are asked through
// AppleScript, Firefox through its address bar. Ardia is one of those browsers
// for `--domain`, but a normal run with Ardia in front never reaches the menu.
//
// Build: ./build.sh (open-passwords-menu.sh, one level up, runs the result)
// Needs Accessibility access for whatever runs it (Raycast).

import AppKit
import ApplicationServices
import Darwin

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

/// `--trace` prints control flow only: bundle id, and whether we activated,
/// sent the shortcut, started the popup watcher, or clicked the toolbar or
/// menu bar. Never window contents, titles, or row text. The watcher itself
/// only adds a line when its own stderr is still open (a spawned watcher has none).
var traceEnabled = false

func trace(_ fact: String) {
    guard traceEnabled else { return }
    FileHandle.standardError.write(Data(("open-passwords-menu: " + fact + "\n").utf8))
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
    guard let window = attribute(app, kAXFocusedWindowAttribute).flatMap({
        CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
    }) else { return nil }
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

/// Launchers that start this command. They are not the app the command acts on.
let launcherBundleIDs: Set<String> = [
    "com.raycast.macos",
    "com.apple.Spotlight",
    "com.runningwithcrayons.Alfred",
]

func isLauncher(_ id: String?) -> Bool {
    guard let id else { return false }
    return launcherBundleIDs.contains(id)
}

/// The front app, once a launcher that just started this has stepped aside.
/// A launcher is never the target, even if it is still front when the wait ends.
func frontApplication() -> NSRunningApplication? {
    waitFor(0.6) { () -> NSRunningApplication? in
        let app = NSWorkspace.shared.frontmostApplication
        return isLauncher(app?.bundleIdentifier) ? nil : app
    }
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

/// Popup titles. A window matches when its title is one of these, or that
/// name plus a separator. Accounts, passwords, codes, and list rows are not read.
let extensionPopupTitles: Set<String> = [
    "Password Manager",
    "iCloud Passwords",
    "iCloud 密码",
    "iCloud 密碼",
]

func axWindows(_ app: AXUIElement) -> [AXUIElement] {
    attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
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
    return role == kAXWindowRole as String || role == kAXSheetRole as String || role == "AXDialog"
}

func windowTitle(_ window: AXUIElement) -> String {
    (attribute(window, kAXTitleAttribute) as? String ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func isPopupSized(_ window: AXUIElement) -> Bool {
    guard isPopupRole(window), let frame = size(window) else { return false }
    return isPopupFrame(frame)
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

/// The pairing screen shows a 6-digit PIN (one text, six single digits, or
/// fields named PIN0…PIN5). Lists are not walked, so account rows are never
/// read. Digits are only tested as a pattern and are not stored or logged.
func isPairingPINPage(_ window: AXUIElement) -> Bool {
    var sixDigitText = false
    var singleDigits = 0
    var pinFields = 0
    func walk(_ element: AXUIElement, depth: Int) {
        if sixDigitText || singleDigits >= 6 || pinFields >= 6 || depth > 12 { return }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        if role == kAXListRole as String || role == kAXOutlineRole as String
            || role == kAXTableRole as String || role == kAXRowRole as String {
            return
        }
        let ident = (attribute(element, "AXDOMIdentifier") as? String)
            ?? (attribute(element, kAXIdentifierAttribute) as? String) ?? ""
        if ident.hasPrefix("PIN"), ident.count > 3, ident.dropFirst(3).allSatisfy({ $0.isASCII && $0.isNumber }) {
            pinFields += 1
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
    walk(window, depth: 0)
    return sixDigitText || singleDigits >= 6 || pinFields >= 6
}

func isPopupFrame(_ frame: CGSize) -> Bool {
    frame.width >= 140 && frame.width <= 520 && frame.height >= 80 && frame.height <= 720
}

/// On-screen windows. Read entry by entry: bridging the whole array to
/// `[NSDictionary]` is not reliable on every SDK, and a failed cast used to
/// look like "no popup", which skipped the key that should have reached it.
/// Names are not logged.
func onScreenWindows() -> [NSDictionary] {
    guard let raw = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) else {
        return []
    }
    var windows: [NSDictionary] = []
    for index in 0..<CFArrayGetCount(raw) {
        guard let value = CFArrayGetValueAtIndex(raw, index) else { continue }
        windows.append(Unmanaged<NSDictionary>.fromOpaque(value).takeUnretainedValue())
    }
    return windows
}

func windowNumber(_ info: NSDictionary, _ key: CFString) -> NSNumber? {
    info.object(forKey: key) as? NSNumber
}

func axElement(_ value: AnyObject?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func elementIdentifier(_ element: AXUIElement) -> String {
    (attribute(element, "AXDOMIdentifier") as? String)
        ?? (attribute(element, kAXIdentifierAttribute) as? String) ?? ""
}

func elementFrame(_ element: AXUIElement) -> CGRect? {
    guard let origin = point(element, kAXPositionAttribute), let frame = size(element) else { return nil }
    return CGRect(origin: origin, size: frame)
}

func elementRole(_ element: AXUIElement) -> String {
    attribute(element, kAXRoleAttribute) as? String ?? ""
}

/// Parent pid, when libproc can see it. Renderer windows are often not owned
/// by the browser pid itself. A miss just means that owner is not related.
func parentProcessID(_ pid: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
}

func isRelatedOwner(_ info: NSDictionary, browser: pid_t) -> Bool {
    let owner = pid_t(windowNumber(info, kCGWindowOwnerPID)?.int32Value ?? -1)
    guard owner > 0 else { return false }
    if owner == browser || parentProcessID(owner) == browser { return true }
    if let bundle = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier,
       bundle == ardiaBundleID || bundle.hasPrefix("com.ardia.") {
        return true
    }
    guard let browserName = NSRunningApplication(processIdentifier: browser)?.localizedName,
          let ownerName = info.object(forKey: kCGWindowOwnerName) as? String else { return false }
    return ownerName == browserName || ownerName.hasPrefix(browserName + " ")
}

struct SeenWindow {
    let id: CGWindowID
    let width: Int
    let height: Int
    let titleMatches: Bool
    let popupSized: Bool
}

func seenWindows(of browser: pid_t) -> [SeenWindow] {
    var windows: [SeenWindow] = []
    for info in onScreenWindows() {
        guard isRelatedOwner(info, browser: browser) else { continue }
        let id = CGWindowID(windowNumber(info, kCGWindowNumber)?.uint32Value ?? 0)
        let layer = windowNumber(info, kCGWindowLayer)?.intValue ?? 0
        guard id != 0, layer >= 0 else { continue }
        var width = 0
        var height = 0
        if let boundsInfo = info.object(forKey: kCGWindowBounds) as? NSDictionary {
            var bounds = CGRect.zero
            if CGRectMakeWithDictionaryRepresentation(boundsInfo, &bounds) {
                width = Int(bounds.width.rounded())
                height = Int(bounds.height.rounded())
            }
        }
        let title = (info.object(forKey: kCGWindowName) as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let popupSized = isPopupFrame(CGSize(width: width, height: height))
        windows.append(SeenWindow(id: id, width: width, height: height,
                                   titleMatches: titleMatchesExtension(title), popupSized: popupSized))
    }
    return windows
}

func encodeSeenWindows(_ windows: [SeenWindow]) -> String {
    if windows.isEmpty { return "-" }
    return windows.map { "\($0.id):\($0.width):\($0.height)" }.sorted().joined(separator: ",")
}

func parseSeenWindows(_ encoded: String) -> [CGWindowID: (Int, Int)] {
    guard encoded != "-", !encoded.isEmpty else { return [:] }
    var prior: [CGWindowID: (Int, Int)] = [:]
    for part in encoded.split(separator: ",") {
        let bits = part.split(separator: ":")
        if bits.count == 3, let id = UInt32(bits[0]), let width = Int(bits[1]), let height = Int(bits[2]) {
            prior[CGWindowID(id)] = (width, height)
        } else if bits.count == 1, let id = UInt32(bits[0]) {
            prior[CGWindowID(id)] = (0, 0)
        }
    }
    return prior
}

/// A popup that showed up after the shortcut. A reused window counts when its
/// size becomes popup-sized, or when its title is the extension's. Titles are
/// not kept. Nil when several untitled candidates disagree.
func appearedPopupWindow(of browser: pid_t, prior: [CGWindowID: (Int, Int)]) -> CGWindowID? {
    var titled: [CGWindowID] = []
    var sized: [CGWindowID] = []
    for window in seenWindows(of: browser) {
        let previous = prior[window.id]
        let wasPopup = previous.map { isPopupFrame(CGSize(width: $0.0, height: $0.1)) } ?? false
        let becamePopup = window.popupSized && (previous == nil || !wasPopup)
        if becamePopup && window.titleMatches { titled.append(window.id) }
        if becamePopup { sized.append(window.id) }
    }
    if let id = titled.first { return id }
    if sized.count == 1 { return sized[0] }
    return nil
}

func showsPINPage(_ app: AXUIElement) -> Bool {
    if axWindows(app).contains(where: { isPopupSized($0) && isPairingPINPage($0) }) { return true }
    guard let focused = axElement(attribute(app, kAXFocusedUIElementAttribute)) else { return false }
    var element: AXUIElement? = focused
    for _ in 0..<8 {
        guard let current = element else { break }
        if isPopupSized(current) && isPairingPINPage(current) { return true }
        if elementIdentifier(current).hasPrefix("PIN"),
           elementIdentifier(current).dropFirst(3).allSatisfy({ $0.isASCII && $0.isNumber }) {
            return true
        }
        element = axElement(attribute(current, kAXParentAttribute))
    }
    return false
}

/// Sends ⌘⇧\ to Ardia and returns. This run does not click the toolbar or the
/// Passwords menu bar afterwards. The shortcut already opens the extension;
/// the toolbar button toggles, so a click in the same run closes it again.
/// Whether Accessibility sees the popup does not matter: a miss used to fall
/// through and open the system Passwords window on top (the lock dialog).
/// Enter is handled later, by the detached watcher, once the user presses it.
func openICloudPasswordsExtension(_ application: NSRunningApplication) {
    var activated = false
    if !application.isActive, let front = NSWorkspace.shared.frontmostApplication,
       front.processIdentifier != application.processIdentifier {
        _ = application.activate(from: front)
        activated = true
    }
    _ = waitFor(0.3) { application.isActive ? true : nil }
    trace("activated \(activated)")
    let beforeWindows = encodeSeenWindows(seenWindows(of: application.processIdentifier))
    sendCommandShiftBackslash()
    trace("sent-keys true")
    startExtensionKeyWatcher(pid: application.processIdentifier, previousWindows: beforeWindows)
    trace("watcher true")
    trace("toolbar false")
    trace("menu-bar false")
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

/// Marks keys this watcher posts, so the tap does not treat them as the user's.
let extensionKeyMark: Int64 = 0x504B

nonisolated(unsafe) var extensionTap: CFMachPort?
nonisolated(unsafe) var extensionPID: pid_t = 0
nonisolated(unsafe) var extensionPrior: [CGWindowID: (Int, Int)] = [:]
nonisolated(unsafe) var extensionPopupID: CGWindowID = 0
nonisolated(unsafe) var extensionPickerUp = false
nonisolated(unsafe) var extensionHandsOff = false
nonisolated(unsafe) var extensionSelectionMoved = false
nonisolated(unsafe) var extensionPosting = false
nonisolated(unsafe) var extensionSwallowEnterUp = false
nonisolated(unsafe) var extensionRewriting = false
nonisolated(unsafe) var extensionFilled = false
nonisolated(unsafe) var extensionDismissed = false
nonisolated(unsafe) var extensionPageTyped = false
nonisolated(unsafe) var extensionUsedFallbackEnter = false
nonisolated(unsafe) var extensionRowCount = -1
nonisolated(unsafe) var extensionRows: [AXUIElement] = []
nonisolated(unsafe) var extensionStarted = Date()

func isDigitKeyCode(_ keyCode: Int64) -> Bool {
    switch keyCode {
    case 29, 18, 19, 20, 21, 23, 22, 26, 28, 25: return true
    case 82, 83, 84, 85, 86, 87, 88, 89, 91, 92: return true
    default: return false
    }
}

func isMarkedSynthetic(_ event: CGEvent) -> Bool {
    extensionPosting || event.getIntegerValueField(.eventSourceUserData) == extensionKeyMark
}

/// One unmodified key, down and up. `kVK_DownArrow` is 0x7D, Return is 36.
func postUnmodifiedKey(_ keyCode: CGKeyCode) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
        event?.flags = []
        event?.setIntegerValueField(.eventSourceUserData, value: extensionKeyMark)
        event?.post(tap: .cghidEventTap)
        usleep(8_000)
    }
}

func isRowFrame(_ frame: CGRect) -> Bool {
    frame.height >= 28 && frame.height <= 88 && frame.width >= 100 && frame.width <= 520
}

func isLargePage(_ element: AXUIElement) -> Bool {
    guard elementRole(element) == "AXWebArea", let frame = elementFrame(element) else { return false }
    return frame.width > 520 && !isPopupFrame(frame.size)
}

func findCredentialList(in root: AXUIElement, depth: Int, budget: inout Int) -> AXUIElement? {
    if budget <= 0 || depth > 16 { return nil }
    budget -= 1
    if elementIdentifier(root) == "credentialList" { return root }
    if isLargePage(root) { return nil }
    for child in children(root) {
        if let found = findCredentialList(in: child, depth: depth + 1, budget: &budget) { return found }
    }
    return nil
}

func extensionDocument(_ element: AXUIElement) -> Bool {
    guard let document = attribute(element, kAXDocumentAttribute) as? String else { return false }
    return document.contains("extension://\(iCloudPasswordsExtensionID)")
}

/// Direct children that are big enough to be a credential row. Labels inside
/// a row are not counted, and nothing's text is read.
func rowElements(of list: AXUIElement) -> [AXUIElement] {
    let skip: Set<String> = ["AXButton", "AXScrollBar", "AXScrollArea", "AXImage", "AXCheckBox"]
    let framed = children(list).filter { child in
        if skip.contains(elementRole(child)) { return false }
        if elementIdentifier(child).hasPrefix("PIN") { return false }
        guard let frame = elementFrame(child) else { return false }
        return isRowFrame(frame)
    }
    return framed.sorted { (elementFrame($0)?.minY ?? 0) < (elementFrame($1)?.minY ?? 0) }
}

func singleListRows(in root: AXUIElement) -> [AXUIElement]? {
    var lists: [[AXUIElement]] = []
    func walk(_ element: AXUIElement, depth: Int) {
        if depth > 8 { return }
        if isLargePage(element) { return }
        let role = elementRole(element)
        if role == kAXListRole as String || role == kAXOutlineRole as String || role == kAXTableRole as String {
            lists.append(rowElements(of: element))
            return
        }
        for child in children(element) { walk(child, depth: depth + 1) }
    }
    walk(root, depth: 0)
    if lists.count == 1 { return lists[0] }
    return nil
}

struct CredentialScan {
    var rows: [AXUIElement] = []
    var known = false
}

/// Nil-known means the extension UI was not visible to Accessibility, so the
/// count must not be treated as zero. Row values are not read.
func scanCredentialRows(in app: AXUIElement) -> CredentialScan {
    var budget = 500
    for window in axWindows(app) {
        if let list = findCredentialList(in: window, depth: 0, budget: &budget) {
            return CredentialScan(rows: rowElements(of: list), known: true)
        }
    }
    if let focused = axElement(attribute(app, kAXFocusedUIElementAttribute)) {
        var focusedBudget = 200
        if let list = findCredentialList(in: focused, depth: 0, budget: &focusedBudget) {
            return CredentialScan(rows: rowElements(of: list), known: true)
        }
        var element: AXUIElement? = focused
        for _ in 0..<8 {
            guard let current = element else { break }
            if elementIdentifier(current) == "credentialList" {
                return CredentialScan(rows: rowElements(of: current), known: true)
            }
            element = axElement(attribute(current, kAXParentAttribute))
        }
    }
    for window in axWindows(app) where isPopupSized(window)
        && (titleMatchesExtension(windowTitle(window)) || extensionDocument(window)) {
        if let rows = singleListRows(in: window) {
            return CredentialScan(rows: rows, known: true)
        }
    }
    return CredentialScan()
}

func hasPressAction(_ element: AXUIElement) -> Bool {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
          let names = names as? [String] else { return false }
    return names.contains(kAXPressAction as String)
}

/// The extension fills a credential when its row is pressed or clicked.
/// Buttons and PIN fields are never the target.
func activateCredential(_ element: AXUIElement) -> Bool {
    if elementIdentifier(element).hasPrefix("PIN") { return false }
    if elementRole(element) == kAXButtonRole as String { return false }
    if hasPressAction(element), AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
        return true
    }
    guard let frame = elementFrame(element), isRowFrame(frame) else { return false }
    click(at: CGPoint(x: frame.midX, y: frame.midY))
    return true
}

func extensionApp() -> AXUIElement {
    let app = AXUIElementCreateApplication(extensionPID)
    AXUIElementSetMessagingTimeout(app, 0.12)
    return app
}

func frontIsExtensionBrowser() -> Bool {
    guard let front = NSWorkspace.shared.frontmostApplication else { return false }
    if front.processIdentifier == extensionPID { return true }
    if let bundle = front.bundleIdentifier, bundle == ardiaBundleID || bundle.hasPrefix("com.ardia.") {
        return true
    }
    return false
}

func focusedIsEditable() -> Bool {
    guard let focused = axElement(attribute(extensionApp(), kAXFocusedUIElementAttribute)) else { return false }
    switch elementRole(focused) {
    case "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField":
        return true
    default:
        return false
    }
}

func isModifierKeyCode(_ keyCode: Int64) -> Bool {
    switch keyCode {
    case 54, 55, 56, 57, 58, 59, 60, 61, 62, 63: return true
    default: return false
    }
}

func extensionPopupStillOpen() -> Bool {
    guard extensionPopupID != 0 else { return false }
    return seenWindows(of: extensionPID).contains { $0.id == extensionPopupID }
}

func refreshExtensionPicker() {
    if extensionHandsOff || extensionFilled { return }
    let app = extensionApp()
    if let id = appearedPopupWindow(of: extensionPID, prior: extensionPrior) {
        if !extensionPickerUp { trace("popup true") }
        extensionPopupID = id
        extensionPickerUp = true
    }
    let scan = scanCredentialRows(in: app)
    if scan.known && !scan.rows.isEmpty {
        // A credential row is showing, so a 6-digit code on that screen is not
        // the pairing PIN.
        if extensionRowCount != scan.rows.count { trace("rows \(scan.rows.count)") }
        extensionRows = scan.rows
        extensionRowCount = scan.rows.count
        extensionPickerUp = true
        return
    }
    if showsPINPage(app) {
        extensionHandsOff = true
        extensionRows = []
        extensionRowCount = -1
        trace("pin true")
        return
    }
    if scan.known {
        if extensionRowCount != 0 { trace("rows 0") }
        extensionRows = []
        extensionRowCount = 0
        extensionPickerUp = true
    } else {
        extensionRows = []
        extensionRowCount = -1
    }
}

/// Click the first row when Accessibility can see it. Otherwise ArrowDown
/// then Enter: with nothing highlighted the extension would close on Enter,
/// and ArrowDown highlights the first row so the following Enter fills it.
func fillFromEnter() {
    guard !extensionHandsOff, !extensionFilled else { return }
    if extensionSelectionMoved {
        extensionPosting = true
        postUnmodifiedKey(36)
        extensionPosting = false
        trace("enter-current true")
        return
    }
    if extensionRowCount >= 1, let row = extensionRows.first, activateCredential(row) {
        extensionFilled = true
        trace("enter-click true")
        return
    }
    extensionPosting = true
    postUnmodifiedKey(0x7D)
    usleep(80_000)
    guard !extensionHandsOff else {
        extensionPosting = false
        return
    }
    postUnmodifiedKey(36)
    extensionPosting = false
    trace(extensionPickerUp ? "enter-keys true" : "enter-fallback true")
}

/// Unmodified Enter fills the first row, or the highlighted row after Up/Down.
/// Enter is not rewritten for the web page once the user has typed, pressed
/// Esc, or the short fallback window has passed — unless the picker itself
/// was actually seen. Nothing is submitted until that Enter. List text is
/// never read. A PIN page is left alone.
func watchExtensionPopup(pid: pid_t, previousWindows: String) -> Never {
    let lock = open(lastRunURL.path + ".extension.lock", O_CREAT | O_RDWR, 0o600)
    guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { exit(0) }
    extensionPID = pid
    extensionPrior = parseSeenWindows(previousWindows)
    extensionStarted = Date()

    let callback: CGEventTapCallBack = { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = extensionTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if isMarkedSynthetic(event) { return Unmanaged.passUnretained(event) }
        let modifiers = event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            if extensionSwallowEnterUp, modifiers.isEmpty, keyCode == 36 || keyCode == 76 {
                extensionSwallowEnterUp = false
                return nil
            }
            return Unmanaged.passUnretained(event)
        }
        guard frontIsExtensionBrowser() else { return Unmanaged.passUnretained(event) }
        if extensionHandsOff || extensionFilled { return Unmanaged.passUnretained(event) }
        let plain = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty
        if plain, isDigitKeyCode(keyCode) {
            // A digit is how the PIN page is filled. Which digit is not recorded.
            if extensionPickerUp {
                extensionHandsOff = true
                trace("digits true")
            } else {
                extensionPageTyped = true
            }
            return Unmanaged.passUnretained(event)
        }
        if modifiers.isEmpty, keyCode == 0x7E || keyCode == 0x7D {
            extensionSelectionMoved = true
            extensionPickerUp = true
            return Unmanaged.passUnretained(event)
        }
        if modifiers.isEmpty, keyCode == 53 {
            extensionDismissed = true
            return Unmanaged.passUnretained(event)
        }
        if plain, !isModifierKeyCode(keyCode), keyCode != 48, keyCode != 36, keyCode != 76,
           keyCode != 0x7E, keyCode != 0x7D, keyCode != 53, !extensionPickerUp {
            extensionPageTyped = true
        }
        guard modifiers.isEmpty, keyCode == 36 || keyCode == 76 else {
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 || extensionRewriting { return nil }
        if extensionDismissed { return Unmanaged.passUnretained(event) }
        if extensionSelectionMoved { return Unmanaged.passUnretained(event) }
        if extensionRowCount < 1, showsPINPage(extensionApp()) {
            extensionHandsOff = true
            trace("pin true")
            return Unmanaged.passUnretained(event)
        }
        if !extensionPickerUp {
            if extensionPageTyped || extensionUsedFallbackEnter { return Unmanaged.passUnretained(event) }
            if Date().timeIntervalSince(extensionStarted) > 12 { return Unmanaged.passUnretained(event) }
            if focusedIsEditable() { return Unmanaged.passUnretained(event) }
            extensionUsedFallbackEnter = true
        }
        extensionSwallowEnterUp = true
        extensionRewriting = true
        DispatchQueue.main.async {
            defer { extensionRewriting = false }
            guard !extensionHandsOff, !extensionFilled else { return }
            fillFromEnter()
        }
        return nil
    }

    let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
    let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                            eventsOfInterest: mask, callback: callback, userInfo: nil)
        ?? CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                             eventsOfInterest: mask, callback: callback, userInfo: nil)
    if let tap {
        extensionTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    } else {
        trace("tap false")
    }

    Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
        refreshExtensionPicker()
        if extensionFilled || extensionHandsOff || extensionDismissed { exit(0) }
        if extensionPopupID != 0, !extensionPopupStillOpen() { exit(0) }
        let age = Date().timeIntervalSince(extensionStarted)
        if !extensionPickerUp && (extensionPageTyped || age > 12) { exit(0) }
        if age > 90 { exit(0) }
    }
    RunLoop.main.run()
    exit(0)
}

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

/// Detached watcher for the Ardia extension picker. `previousWindows` is the
/// on-screen windows of Ardia and its helpers before ⌘⇧\. Stdio is discarded
/// so Raycast does not wait.
func startExtensionKeyWatcher(pid browser: pid_t, previousWindows: String) {
    guard let path = Bundle.main.executablePath ?? CommandLine.arguments.first else { return }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    var files: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&files)
    for fd: Int32 in 0...2 { posix_spawn_file_actions_addopen(&files, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
    var tokens = [path, "--extension-keys", String(browser), previousWindows.isEmpty ? "-" : previousWindows]
    if traceEnabled { tokens.append("--trace") }
    var pid: pid_t = 0
    let argv = tokens.map { strdup($0) } + [nil]
    posix_spawn(&pid, path, &files, &attributes, argv, environ)
    argv.forEach { free($0) }
    posix_spawn_file_actions_destroy(&files)
    posix_spawnattr_destroy(&attributes)
}

// MARK: - Main

guard AXIsProcessTrusted() else { fail("Accessibility access is needed (System Settings → Privacy & Security → Accessibility).") }

let args = Array(CommandLine.arguments.dropFirst())
traceEnabled = args.contains("--trace")
let command = args.first { $0 != "--trace" }
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
if command == "--extension-keys" {
    let positional = args.filter { $0 != "--trace" }
    guard positional.count >= 2, let pid = pid_t(positional[1]), pid > 0 else { exit(1) }
    let encoded = positional.count >= 3 ? positional[2] : "-"
    watchExtensionPopup(pid: pid, previousWindows: encoded)
}

let front = frontApplication()
trace("front \(front?.bundleIdentifier ?? "(none)")")
// Ardia: the shortcut, then stop. Never the menu bar in this same run.
if let front, front.bundleIdentifier == ardiaBundleID {
    openICloudPasswordsExtension(front)
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
trace("toolbar false")
trace("menu-bar true")
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

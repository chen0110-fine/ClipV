import Cocoa
import SwiftUI
import Carbon

// MARK: - Data Models

enum ClipKind: String, Codable, CaseIterable {
    case text
    case link
    case code
    case color
    case image
    case file
}

struct ClipItem: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var kind: ClipKind
    var createdAt: Date
    var sourceAppName: String
    var sourceBundleID: String?
    var isPinned: Bool
    var copyCount: Int
    var imageFileName: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var filePaths: [String]?

    var previewText: String {
        switch kind {
        case .image:
            if let w = imageWidth, let h = imageHeight {
                return "图片 · \(w) × \(h)"
            }
            return "图片"
        case .file:
            guard let paths = filePaths, let first = paths.first else { return text }
            let name = URL(fileURLWithPath: first).lastPathComponent
            return paths.count > 1 ? "\(name) 等 \(paths.count) 个文件" : name
        default:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "(空白)" }
            let lines = trimmed
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return String(lines.prefix(3).joined(separator: "\n").prefix(240))
        }
    }

    var fileSubtitle: String? {
        guard kind == .file, let paths = filePaths, let first = paths.first else { return nil }
        let url = URL(fileURLWithPath: first)
        let dir = url.deletingLastPathComponent().path
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        if paths.count == 1,
           let attrs = try? FileManager.default.attributesOfItem(atPath: first),
           let size = attrs[.size] as? Int64 {
            let formatted = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            return "\(dir) · \(formatted)"
        }
        return dir
    }

    var relativeTimeText: String {
        let diff = Int(Date().timeIntervalSince(createdAt))
        if diff < 10 { return "刚刚" }
        if diff < 60 { return "\(diff)秒前" }
        if diff < 3600 { return "\(diff / 60)分钟前" }
        if diff < 86400 { return "\(diff / 3600)小时前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: createdAt)
    }
}

// MARK: - Content Classifier & Icon Cache

enum ContentClassifier {
    static func classify(_ raw: String) -> ClipKind {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isHexColor(trimmed) { return .color }
        if isURL(trimmed) { return .link }
        if isLikelyCode(trimmed) { return .code }
        return .text
    }

    static func isHexColor(_ str: String) -> Bool {
        let pattern = "^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3}|[A-Fa-f0-9]{8})$"
        return str.range(of: pattern, options: .regularExpression) != nil
    }

    static func parseHexColor(_ str: String) -> NSColor? {
        var hex = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 {
            hex = hex.map { "\($0)\($0)" }.joined()
        }
        guard hex.count == 6 || hex.count == 8,
              let val = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 6 {
            return NSColor(
                srgbRed: CGFloat((val >> 16) & 0xFF) / 255.0,
                green: CGFloat((val >> 8) & 0xFF) / 255.0,
                blue: CGFloat(val & 0xFF) / 255.0,
                alpha: 1.0
            )
        } else {
            return NSColor(
                srgbRed: CGFloat((val >> 24) & 0xFF) / 255.0,
                green: CGFloat((val >> 16) & 0xFF) / 255.0,
                blue: CGFloat((val >> 8) & 0xFF) / 255.0,
                alpha: CGFloat(val & 0xFF) / 255.0
            )
        }
    }

    static func isURL(_ str: String) -> Bool {
        guard !str.contains("\n"),
              let url = URL(string: str),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp", "ssh", "file"].contains(scheme),
              url.host != nil else { return false }
        return true
    }

    static func isLikelyCode(_ str: String) -> Bool {
        let lines = str.components(separatedBy: .newlines)
        let signals = [
            "func ", "import ", "const ", "let ", "var ", "class ", "struct ",
            "def ", "return ", "if (", "for (", "=>", "->", "#include",
            "SELECT ", "git ", "brew ", "npm ", "curl ", "docker ", "sudo ", "</"
        ]
        var hits = 0
        for s in signals where str.contains(s) {
            hits += 1
            if hits >= 2 { return true }
        }
        return lines.count >= 2 && str.contains("{") && str.contains("}")
    }
}

final class IconCache {
    static let shared = IconCache()
    private var appCache: [String: NSImage] = [:]
    private var fileCache: [String: NSImage] = [:]

    func appIcon(for bundleID: String?) -> NSImage? {
        guard let bid = bundleID, !bid.isEmpty else { return nil }
        if let cached = appCache[bid] { return cached }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else {
            return nil
        }
        let img = NSWorkspace.shared.icon(forFile: appURL.path)
        img.size = NSSize(width: 14, height: 14)
        appCache[bid] = img
        return img
    }

    func fileIcon(for path: String) -> NSImage {
        if let cached = fileCache[path] { return cached }
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 28, height: 28)
        fileCache[path] = img
        return img
    }
}

// MARK: - Clipboard Store & Pasteboard Monitor

final class ClipboardStore: ObservableObject {
    static let shared = ClipboardStore()

    @Published var items: [ClipItem] = []
    @Published var searchQuery: String = ""
    @Published var showPinnedOnly: Bool = false
    @Published var selectedItemID: UUID?
    @Published var isAccessibilityGranted: Bool = AXIsProcessTrusted()
    @Published var statusToast: String?
    @Published var launchAtLoginEnabled: Bool = false
    @Published var isSearchActive: Bool = false

    private let maxItems = 150
    private let maxImages = 25
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var isInternalWrite = false
    private var imageThumbCache: [UUID: NSImage] = [:]

    let storageDir: URL
    let imagesDir: URL
    let historyFile: URL
    let launchAgentLabel = "io.github.chen0110.clipv"
    let launchAgentFile: URL

    /// Ignore sensitive entries written by password managers (1Password, Keychain, Bitwarden, etc.)
    private let ignoredTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType"
    ]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storageDir = appSupport.appendingPathComponent("ClipV", isDirectory: true)
        imagesDir = storageDir.appendingPathComponent("Images", isDirectory: true)
        historyFile = storageDir.appendingPathComponent("history.json")

        let home = FileManager.default.homeDirectoryForCurrentUser
        launchAgentFile = home.appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")

        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        loadHistory()
        launchAtLoginEnabled = FileManager.default.fileExists(atPath: launchAgentFile.path)

        if items.isEmpty {
            seedWelcomeItems()
        }
        selectedItemID = filteredItems.first?.id
        startMonitoring()
    }

    var filteredItems: [ClipItem] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = items.filter { item in
            if showPinnedOnly && !item.isPinned { return false }
            if query.isEmpty { return true }
            return item.text.lowercased().contains(query)
                || item.sourceAppName.lowercased().contains(query)
                || (item.filePaths?.joined(separator: " ").lowercased().contains(query) ?? false)
        }
        return base.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned && !b.isPinned }
            return a.createdAt > b.createdAt
        }
    }

    var selectedItem: ClipItem? {
        if let id = selectedItemID, let found = filteredItems.first(where: { $0.id == id }) {
            return found
        }
        return filteredItems.first
    }

    func refreshSelectionAfterFilter() {
        let list = filteredItems
        if let id = selectedItemID, list.contains(where: { $0.id == id }) { return }
        selectedItemID = list.first?.id
    }

    func moveSelection(delta: Int) {
        let list = filteredItems
        guard !list.isEmpty else { return }
        guard let currentID = selectedItemID,
              let idx = list.firstIndex(where: { $0.id == currentID }) else {
            selectedItemID = list.first?.id
            return
        }
        let nextIndex = max(0, min(list.count - 1, idx + delta))
        selectedItemID = list[nextIndex].id
    }

    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
        if let timer = timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func checkPasteboard() {
        let trustedNow = AXIsProcessTrusted()
        if trustedNow != isAccessibilityGranted {
            isAccessibilityGranted = trustedNow
        }

        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        if isInternalWrite {
            isInternalWrite = false
            return
        }

        let types = pb.types ?? []
        for t in types where ignoredTypes.contains(t.rawValue) {
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let appName = frontApp?.localizedName ?? "macOS"
        let bundleID = frontApp?.bundleIdentifier

        // 1. Real files copied from Finder / Desktop
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            recordFileItems(urls, appName: appName, bundleID: bundleID)
            return
        }

        // 2. Images (screenshots or browser "Copy Image" that may also attach URL/HTML)
        let hasImageType = types.contains(.png) || types.contains(.tiff)
        let hasRichTextOnly = types.contains(.rtf) && !types.contains(.png)
        if hasImageType && !hasRichTextOnly, let img = NSImage(pasteboard: pb) {
            recordImageItem(img, appName: appName, bundleID: bundleID)
            return
        }

        // 3. Plain text / code / links / hex colors
        if let str = pb.string(forType: .string) {
            let clean = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            recordTextItem(str, appName: appName, bundleID: bundleID)
        }
    }

    func recordFileItems(_ urls: [URL], appName: String, bundleID: String?) {
        let paths = urls.map(\.path)
        let summary = urls.map(\.lastPathComponent).joined(separator: ", ")

        DispatchQueue.main.async {
            if let idx = self.items.firstIndex(where: { $0.kind == .file && $0.filePaths == paths }) {
                var existing = self.items.remove(at: idx)
                existing.createdAt = Date()
                existing.copyCount += 1
                existing.sourceAppName = appName
                existing.sourceBundleID = bundleID
                self.items.insert(existing, at: 0)
                self.selectedItemID = existing.id
            } else {
                let newItem = ClipItem(
                    id: UUID(),
                    text: summary,
                    kind: .file,
                    createdAt: Date(),
                    sourceAppName: appName,
                    sourceBundleID: bundleID,
                    isPinned: false,
                    copyCount: 1,
                    filePaths: paths
                )
                self.items.insert(newItem, at: 0)
                self.selectedItemID = newItem.id
            }
            self.trimAndSave()
        }
    }

    func recordTextItem(_ text: String, appName: String, bundleID: String?) {
        DispatchQueue.main.async {
            if let idx = self.items.firstIndex(where: { $0.kind != .image && $0.kind != .file && $0.text == text }) {
                var existing = self.items.remove(at: idx)
                existing.createdAt = Date()
                existing.copyCount += 1
                existing.sourceAppName = appName
                existing.sourceBundleID = bundleID
                self.items.insert(existing, at: 0)
                self.selectedItemID = existing.id
            } else {
                let newItem = ClipItem(
                    id: UUID(),
                    text: text,
                    kind: ContentClassifier.classify(text),
                    createdAt: Date(),
                    sourceAppName: appName,
                    sourceBundleID: bundleID,
                    isPinned: false,
                    copyCount: 1
                )
                self.items.insert(newItem, at: 0)
                self.selectedItemID = newItem.id
            }
            self.trimAndSave()
        }
    }

    func recordImageItem(_ image: NSImage, appName: String, bundleID: String?) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else { return }

        let id = UUID()
        let fileName = "\(id.uuidString).png"
        let fileURL = imagesDir.appendingPathComponent(fileName)
        do {
            try pngData.write(to: fileURL, options: .atomic)
        } catch {
            return
        }

        let w = bitmap.pixelsWide
        let h = bitmap.pixelsHigh

        DispatchQueue.main.async {
            let newItem = ClipItem(
                id: id,
                text: "图片 \(w)×\(h)",
                kind: .image,
                createdAt: Date(),
                sourceAppName: appName,
                sourceBundleID: bundleID,
                isPinned: false,
                copyCount: 1,
                imageFileName: fileName,
                imageWidth: w,
                imageHeight: h
            )
            self.items.insert(newItem, at: 0)
            self.selectedItemID = newItem.id
            self.trimAndSave()
        }
    }

    func loadImage(for item: ClipItem) -> NSImage? {
        if let cached = imageThumbCache[item.id] { return cached }
        guard let name = item.imageFileName else { return nil }
        let url = imagesDir.appendingPathComponent(name)
        guard let img = NSImage(contentsOf: url) else { return nil }
        imageThumbCache[item.id] = img
        return img
    }

    func togglePin(_ item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isPinned.toggle()
        showToast(items[idx].isPinned ? "已置顶" : "已取消置顶")
        saveHistory()
    }

    func deleteItem(_ item: ClipItem) {
        let list = filteredItems
        let currentIdx = list.firstIndex(where: { $0.id == item.id }) ?? 0

        imageThumbCache.removeValue(forKey: item.id)
        if let imgName = item.imageFileName {
            try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(imgName))
        }
        items.removeAll { $0.id == item.id }
        saveHistory()

        let updated = filteredItems
        selectedItemID = updated.isEmpty ? nil : updated[min(currentIdx, updated.count - 1)].id
        showToast("已删除")
    }

    func clearUnpinned() {
        let removed = items.filter { !$0.isPinned }
        for item in removed {
            imageThumbCache.removeValue(forKey: item.id)
            if let imgName = item.imageFileName {
                try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(imgName))
            }
        }
        items.removeAll { !$0.isPinned }
        saveHistory()
        selectedItemID = filteredItems.first?.id
        showToast("已清空历史")
    }

    func copyToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        isInternalWrite = true
        pb.clearContents()

        if item.kind == .file, let paths = item.filePaths {
            let existingURLs = paths
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) as NSURL }
            if !existingURLs.isEmpty {
                pb.writeObjects(existingURLs)
            } else {
                pb.setString(item.text, forType: .string)
            }
        } else if item.kind == .image, let img = loadImage(for: item) {
            pb.writeObjects([img])
        } else {
            pb.setString(item.text, forType: .string)
        }
        lastChangeCount = pb.changeCount

        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            var updated = items.remove(at: idx)
            updated.createdAt = Date()
            updated.copyCount += 1
            items.insert(updated, at: 0)
            selectedItemID = updated.id
            saveHistory()
        }
    }

    func showToast(_ message: String) {
        statusToast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.statusToast == message {
                self?.statusToast = nil
            }
        }
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isAccessibilityGranted = AXIsProcessTrusted()
        }
    }

    func refreshAccessibilityState() {
        isAccessibilityGranted = AXIsProcessTrusted()
    }

    func toggleLaunchAtLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: launchAgentFile.path) {
            try? fm.removeItem(at: launchAgentFile)
            launchAtLoginEnabled = false
            showToast("已关闭自启")
        } else {
            let execPath = Bundle.main.executablePath ?? "/Applications/ClipV.app/Contents/MacOS/ClipV"
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(launchAgentLabel)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(execPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>KeepAlive</key>
                <true/>
                <key>ProcessType</key>
                <string>Interactive</string>
            </dict>
            </plist>
            """
            try? fm.createDirectory(at: launchAgentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? plistContent.write(to: launchAgentFile, atomically: true, encoding: .utf8)
            launchAtLoginEnabled = true
            showToast("已开启自启")
        }
    }

    private func trimAndSave() {
        var imageCount = 0
        items.removeAll { item in
            if item.kind == .image {
                imageCount += 1
                if !item.isPinned && imageCount > maxImages {
                    imageThumbCache.removeValue(forKey: item.id)
                    if let name = item.imageFileName {
                        try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name))
                    }
                    return true
                }
            }
            return false
        }

        if items.count > maxItems {
            var count = 0
            items.removeAll { item in
                count += 1
                if !item.isPinned && count > maxItems {
                    imageThumbCache.removeValue(forKey: item.id)
                    if let name = item.imageFileName {
                        try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name))
                    }
                    return true
                }
                return false
            }
        }
        saveHistory()
    }

    private func saveHistory() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: historyFile, options: .atomic)
        } catch {}
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([ClipItem].self, from: data) {
            self.items = decoded
        }
    }

    private func seedWelcomeItems() {
        let now = Date()
        items = [
            ClipItem(
                id: UUID(),
                text: "按 ⌥V 随时呼出，单击任意卡片直接粘贴，拖拽顶部可自由移动位置。",
                kind: .text,
                createdAt: now,
                sourceAppName: "ClipV",
                sourceBundleID: nil,
                isPinned: true,
                copyCount: 1
            )
        ]
        saveHistory()
    }
}

// MARK: - Focus-Safe Non-Activating Panel & Custom Dragging

extension NSView {
    @objc func clipv_acceptsFirstMouse(_ event: NSEvent?) -> Bool { true }

    static func enableFirstMouseEverywhere() {
        guard let original = class_getInstanceMethod(NSView.self, #selector(NSView.acceptsFirstMouse(for:))),
              let replacement = class_getInstanceMethod(NSView.self, #selector(NSView.clipv_acceptsFirstMouse(_:))) else {
            return
        }
        method_exchangeImplementations(original, replacement)
    }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Pure AppKit window drag area that repositions the panel smoothly
/// without activating ClipV or stealing focus from the user's active input field.
final class FocusSafeDragNSView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        let startMouse = NSEvent.mouseLocation
        let startOrigin = win.frame.origin
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }

        while let nextEvent = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if nextEvent.type == .leftMouseUp { break }
            let current = NSEvent.mouseLocation
            win.setFrameOrigin(NSPoint(
                x: startOrigin.x + (current.x - startMouse.x),
                y: startOrigin.y + (current.y - startMouse.y)
            ))
        }
    }
}

struct WindowDragHandleArea: NSViewRepresentable {
    func makeNSView(context: Context) -> FocusSafeDragNSView {
        FocusSafeDragNSView()
    }
    func updateNSView(_ nsView: FocusSafeDragNSView, context: Context) {}
}

final class FloatingClipboardPanel: NSPanel {
    var allowKeyFocus: Bool = false
    var onKeyAction: ((NSEvent) -> Bool)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .popUpMenu
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        self.isMovableByWindowBackground = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = true
    }

    override var canBecomeKey: Bool { allowKeyFocus }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if let handler = onKeyAction, handler(event) {
                return
            }
        }
        super.sendEvent(event)
    }
}

// MARK: - Global Carbon Hotkey Manager (Option + V & Overlay Navigation)

final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()

    private var mainHotKeyRef: EventHotKeyRef?
    private var navHotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?

    var onTogglePanel: (() -> Void)?
    var onNavKey: ((UInt32) -> Void)?

    static let idToggle: UInt32 = 1
    static let idUp: UInt32 = 2
    static let idDown: UInt32 = 3
    static let idReturn: UInt32 = 4
    static let idKeypadEnter: UInt32 = 5
    static let idEscape: UInt32 = 6
    static let idPin: UInt32 = 7
    static let idDelete: UInt32 = 8
    static let idDigitBase: UInt32 = 100

    func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData, let event = event else { return noErr }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if status == noErr {
                    DispatchQueue.main.async {
                        if hkID.id == GlobalHotKeyManager.idToggle {
                            manager.onTogglePanel?()
                        } else {
                            manager.onNavKey?(hkID.id)
                        }
                    }
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }

    func registerOptionV() {
        installHandlerIfNeeded()
        if let ref = mainHotKeyRef {
            UnregisterEventHotKey(ref)
            mainHotKeyRef = nil
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x434C5056), id: Self.idToggle)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &mainHotKeyRef
        )
    }

    func registerOverlayNavigationKeys() {
        unregisterOverlayNavigationKeys()
        installHandlerIfNeeded()

        let bindings: [(UInt32, UInt32, UInt32)] = [
            (UInt32(kVK_UpArrow), 0, Self.idUp),
            (UInt32(kVK_DownArrow), 0, Self.idDown),
            (UInt32(kVK_Return), 0, Self.idReturn),
            (UInt32(kVK_ANSI_KeypadEnter), 0, Self.idKeypadEnter),
            (UInt32(kVK_Escape), 0, Self.idEscape),
            (UInt32(kVK_ANSI_P), UInt32(cmdKey), Self.idPin),
            (UInt32(kVK_Delete), UInt32(cmdKey), Self.idDelete)
        ]

        for (keyCode, mods, id) in bindings {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x434C5056), id: id)
            if RegisterEventHotKey(keyCode, mods, hkID, GetApplicationEventTarget(), 0, &ref) == noErr,
               let r = ref {
                navHotKeyRefs.append(r)
            }
        }

        let digitCodes: [Int] = [
            kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3,
            kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
            kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
        ]
        for (i, code) in digitCodes.enumerated() {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x434C5056), id: Self.idDigitBase + UInt32(i + 1))
            if RegisterEventHotKey(UInt32(code), UInt32(cmdKey), hkID, GetApplicationEventTarget(), 0, &ref) == noErr,
               let r = ref {
                navHotKeyRefs.append(r)
            }
        }
    }

    func unregisterOverlayNavigationKeys() {
        for ref in navHotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        navHotKeyRefs.removeAll()
    }
}

// MARK: - Minimalist Native macOS Views

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct ClipboardMainView: View {
    @ObservedObject var store: ClipboardStore
    @FocusState private var isSearchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var onActivateSearch: () -> Void
    var onSelectAndPaste: (ClipItem) -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(spacing: 0) {
                topGrabberAndSearchBar
                cardListSection
                minimalFooterBar
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color.white.opacity(0.24), Color.white.opacity(0.06)]
                            : [Color.white.opacity(0.75), Color.black.opacity(0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .onChange(of: store.searchQuery) { _, _ in
            store.refreshSelectionAfterFilter()
        }
        .onChange(of: store.showPinnedOnly) { _, _ in
            store.refreshSelectionAfterFilter()
        }
        .onChange(of: store.isSearchActive) { _, active in
            isSearchFocused = active
        }
    }

    private var topGrabberAndSearchBar: some View {
        ZStack {
            WindowDragHandleArea()

            VStack(spacing: 6) {
                Capsule()
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: 36, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                    .allowsHitTesting(false)

                HStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.8))

                        if store.isSearchActive {
                            TextField("搜索", text: $store.searchQuery)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13.5))
                                .focused($isSearchFocused)
                        } else {
                            Button {
                                onActivateSearch()
                            } label: {
                                Text("搜索")
                                    .font(.system(size: 13.5))
                                    .foregroundColor(.secondary.opacity(0.65))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }

                        if !store.searchQuery.isEmpty {
                            Button {
                                store.searchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.055))
                    )

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            store.showPinnedOnly.toggle()
                        }
                    } label: {
                        Image(systemName: store.showPinnedOnly ? "pin.fill" : "pin")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(store.showPinnedOnly ? .orange : .secondary)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(
                                        store.showPinnedOnly
                                            ? Color.orange.opacity(0.16)
                                            : Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.05)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(store.showPinnedOnly ? "显示全部" : "仅看置顶")

                    Button {
                        store.clearUnpinned()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("清空非置顶记录")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var cardListSection: some View {
        Group {
            let list = store.filteredItems
            if list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: store.showPinnedOnly ? "pin.slash" : "doc.on.clipboard")
                        .font(.system(size: 26, weight: .light))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(store.showPinnedOnly ? "暂无置顶内容" : (store.searchQuery.isEmpty ? "剪贴板为空" : "无匹配内容"))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 6) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                                ClipCardView(
                                    item: item,
                                    index: index,
                                    isSelected: store.selectedItem?.id == item.id,
                                    image: item.kind == .image ? store.loadImage(for: item) : nil,
                                    onHover: {
                                        if store.selectedItemID != item.id {
                                            store.selectedItemID = item.id
                                        }
                                    },
                                    onPaste: {
                                        onSelectAndPaste(item)
                                    },
                                    onTogglePin: {
                                        store.togglePin(item)
                                    },
                                    onDelete: {
                                        store.deleteItem(item)
                                    }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: store.selectedItemID) { _, newID in
                        if let id = newID {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var minimalFooterBar: some View {
        ZStack {
            WindowDragHandleArea()

            HStack(spacing: 8) {
                if !store.isAccessibilityGranted {
                    Button {
                        store.requestAccessibilityPermission()
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 6, height: 6)
                            Text("开启辅助功能以自动粘贴")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.orange)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.orange.opacity(0.8))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else if let toast = store.statusToast {
                    Text(toast)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.accentColor)
                        .allowsHitTesting(false)
                } else {
                    Text("单击粘贴 · ⌘1-9 · Esc")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.75))
                        .allowsHitTesting(false)
                }

                Spacer()

                Text("\(store.filteredItems.count) 条")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.65))
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 32)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
    }
}

struct ClipCardView: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let image: NSImage?
    let onHover: () -> Void
    let onPaste: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var active: Bool { isSelected }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                onPaste()
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    contentBody

                    HStack(spacing: 5) {
                        if let appIcon = IconCache.shared.appIcon(for: item.sourceBundleID) {
                            Image(nsImage: appIcon)
                                .resizable()
                                .frame(width: 12, height: 12)
                                .clipShape(RoundedRectangle(cornerRadius: 2.5))
                        }

                        Text(item.sourceAppName)
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary.opacity(0.75))
                            .lineLimit(1)

                        Text("·")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary.opacity(0.45))

                        Text(item.relativeTimeText)
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary.opacity(0.65))

                        Spacer()

                        if item.isPinned && !active {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9.5))
                                .foregroundColor(.orange.opacity(0.85))
                        }

                        if index < 9 {
                            Text("⌘\(index + 1)")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundColor(active ? .accentColor : .secondary.opacity(0.5))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)

            if active {
                HStack(spacing: 4) {
                    Button {
                        onTogglePin()
                    } label: {
                        Image(systemName: item.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(item.isPinned ? .orange : .secondary)
                            .frame(width: 22, height: 22)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(item.isPinned ? "取消置顶" : "置顶")

                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(.secondary)
                            .frame(width: 22, height: 22)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("删除")
                }
                .padding(.top, 7)
                .padding(.trailing, 8)
                .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(cardFillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(cardStrokeColor, lineWidth: active ? 1 : 0.5)
        )
        .animation(.easeOut(duration: 0.12), value: active)
        .onHover { hovering in
            if hovering {
                onHover()
            }
        }
    }

    @ViewBuilder
    private var contentBody: some View {
        switch item.kind {
        case .file:
            HStack(spacing: 10) {
                if let firstPath = item.filePaths?.first {
                    Image(nsImage: IconCache.shared.fileIcon(for: firstPath))
                        .resizable()
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: "doc.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.previewText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if let sub = item.fileSubtitle {
                        Text(sub)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(.trailing, active ? 46 : 0)

        case .image:
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 112, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Label(item.previewText, systemImage: "photo")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

        case .color:
            HStack(spacing: 10) {
                if let nsColor = ContentClassifier.parseHexColor(item.text) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: nsColor))
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.8)
                        )
                }
                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
                    .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
            }

        case .link:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.accentColor.opacity(0.85))
                    .padding(.top, 2)
                Text(item.previewText)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .padding(.trailing, active ? 46 : 0)

        case .code:
            Text(item.previewText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary.opacity(0.92))
                .lineSpacing(2)
                .lineLimit(3)
                .padding(.trailing, active ? 46 : 0)

        case .text:
            Text(item.previewText)
                .font(.system(size: 13))
                .foregroundColor(.primary.opacity(0.95))
                .lineSpacing(2.5)
                .lineLimit(3)
                .padding(.trailing, active ? 46 : 0)
        }
    }

    private var cardFillColor: Color {
        if active {
            return colorScheme == .dark
                ? Color.white.opacity(0.12)
                : Color.white.opacity(0.72)
        }
        return colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.white.opacity(0.36)
    }

    private var cardStrokeColor: Color {
        if active {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.55 : 0.45)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06)
    }
}

// MARK: - Application Delegate & Overlay Controller

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingClipboardPanel!
    private var previousApp: NSRunningApplication?
    private var globalMouseMonitor: Any?
    private let store = ClipboardStore.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSView.enableFirstMouseEverywhere()
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()
        setupFloatingPanel()

        GlobalHotKeyManager.shared.onTogglePanel = { [weak self] in
            self?.togglePanel()
        }
        GlobalHotKeyManager.shared.onNavKey = { [weak self] hkID in
            self?.handleOverlayCarbonNavKey(hkID)
        }
        GlobalHotKeyManager.shared.registerOptionV()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipV")
            button.image?.isTemplate = true
            button.toolTip = "ClipV (⌥V)"
        }

        let menu = NSMenu()

        let openItem = NSMenuItem(title: "打开剪贴板 (⌥V)", action: #selector(openPanelFromMenu), keyEquivalent: "v")
        openItem.keyEquivalentModifierMask = [.option]
        menu.addItem(openItem)

        menu.addItem(.separator())

        let autoPasteItem = NSMenuItem(title: "辅助功能权限", action: #selector(requestAccessibilityFromMenu), keyEquivalent: "")
        menu.addItem(autoPasteItem)

        let launchItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLoginFromMenu), keyEquivalent: "")
        launchItem.state = store.launchAtLoginEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "清空非置顶记录", action: #selector(clearHistoryFromMenu), keyEquivalent: "")
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 ClipV", action: #selector(quitApp), keyEquivalent: "q")
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    private func setupFloatingPanel() {
        let rect = NSRect(x: 0, y: 0, width: 356, height: 472)
        panel = FloatingClipboardPanel(contentRect: rect)

        let contentView = ClipboardMainView(
            store: store,
            onActivateSearch: { [weak self] in
                self?.activateSearchBox()
            },
            onSelectAndPaste: { [weak self] item in
                self?.confirmAndPaste(item)
            },
            onClose: { [weak self] in
                self?.hidePanel()
            }
        )

        panel.contentView = FirstMouseHostingView(rootView: contentView)

        panel.onKeyAction = { [weak self] event in
            guard let self = self else { return false }
            return self.handlePanelKeyDown(event)
        }
    }

    private func activateSearchBox() {
        GlobalHotKeyManager.shared.unregisterOverlayNavigationKeys()
        panel.allowKeyFocus = true
        store.isSearchActive = true
        panel.makeKeyAndOrderFront(nil)
    }

    private func handleOverlayCarbonNavKey(_ hkID: UInt32) {
        guard panel.isVisible else { return }

        switch hkID {
        case GlobalHotKeyManager.idUp:
            store.moveSelection(delta: -1)
        case GlobalHotKeyManager.idDown:
            store.moveSelection(delta: 1)
        case GlobalHotKeyManager.idReturn, GlobalHotKeyManager.idKeypadEnter:
            if let item = store.selectedItem {
                confirmAndPaste(item)
            }
        case GlobalHotKeyManager.idEscape:
            hidePanel()
        case GlobalHotKeyManager.idPin:
            if let item = store.selectedItem {
                store.togglePin(item)
            }
        case GlobalHotKeyManager.idDelete:
            if let item = store.selectedItem {
                store.deleteItem(item)
            }
        default:
            if hkID > GlobalHotKeyManager.idDigitBase {
                let idx = Int(hkID - GlobalHotKeyManager.idDigitBase) - 1
                let list = store.filteredItems
                if idx >= 0 && idx < list.count {
                    confirmAndPaste(list[idx])
                }
            }
        }
    }

    private func handlePanelKeyDown(_ event: NSEvent) -> Bool {
        if let textView = panel.firstResponder as? NSTextView, textView.hasMarkedText() {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 53: // Escape
            hidePanel()
            return true
        case 126: // Up
            store.moveSelection(delta: -1)
            return true
        case 125: // Down
            store.moveSelection(delta: 1)
            return true
        case 36, 76: // Return / Enter
            if let item = store.selectedItem {
                confirmAndPaste(item)
            }
            return true
        case 51: // Cmd + Delete
            if flags.contains(.command), let item = store.selectedItem {
                store.deleteItem(item)
                return true
            }
            return false
        case 35: // Cmd + P
            if flags.contains(.command), let item = store.selectedItem {
                store.togglePin(item)
                return true
            }
            return false
        default:
            if flags.contains(.command),
               let chars = event.charactersIgnoringModifiers,
               let digit = Int(chars),
               (1...9).contains(digit) {
                let list = store.filteredItems
                let idx = digit - 1
                if idx < list.count {
                    confirmAndPaste(list[idx])
                }
                return true
            }
            return false
        }
    }

    func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        store.refreshAccessibilityState()
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }

        store.searchQuery = ""
        store.isSearchActive = false
        panel.allowKeyFocus = false
        store.selectedItemID = store.filteredItems.first?.id

        let mouseLoc = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        if let screen = targetScreen {
            let visible = screen.visibleFrame
            let w = panel.frame.width
            let h = panel.frame.height
            let margin: CGFloat = 14

            var x = mouseLoc.x - 40
            var y = mouseLoc.y - h - 14
            if y < visible.minY + margin {
                y = min(mouseLoc.y + 18, visible.maxY - h - margin)
            }
            x = max(visible.minX + margin, min(x, visible.maxX - w - margin))
            y = max(visible.minY + margin, min(y, visible.maxY - h - margin))

            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }

        GlobalHotKeyManager.shared.registerOverlayNavigationKeys()
        installOutsideClickMonitor()
    }

    func hidePanel() {
        GlobalHotKeyManager.shared.unregisterOverlayNavigationKeys()
        removeOutsideClickMonitor()

        let wasSearchActive = store.isSearchActive
        store.isSearchActive = false
        panel.allowKeyFocus = false

        guard panel.isVisible else { return }
        panel.orderOut(nil)

        if wasSearchActive, let targetApp = previousApp {
            targetApp.activate()
        }
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.panel.isVisible else { return }
            let mouseLoc = NSEvent.mouseLocation
            if !self.panel.frame.contains(mouseLoc) {
                self.hidePanel()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
    }

    private func confirmAndPaste(_ item: ClipItem) {
        let wasSearchActive = store.isSearchActive
        store.copyToPasteboard(item)

        GlobalHotKeyManager.shared.unregisterOverlayNavigationKeys()
        removeOutsideClickMonitor()
        store.isSearchActive = false
        panel.allowKeyFocus = false
        panel.orderOut(nil)

        if !AXIsProcessTrusted() {
            store.requestAccessibilityPermission()
            return
        }

        if wasSearchActive, let targetApp = previousApp {
            targetApp.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) {
                Self.postSyntheticCommandV()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
                Self.postSyntheticCommandV()
            }
        }
    }

    private static func postSyntheticCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKeyCode: CGKeyCode = CGKeyCode(kVK_ANSI_V)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    @objc private func openPanelFromMenu() {
        showPanel()
    }

    @objc private func requestAccessibilityFromMenu() {
        store.requestAccessibilityPermission()
    }

    @objc private func toggleLaunchAtLoginFromMenu() {
        store.toggleLaunchAtLogin()
    }

    @objc private func clearHistoryFromMenu() {
        store.clearUnpinned()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        store.refreshAccessibilityState()
        if menu.items.count > 3 {
            let axItem = menu.items[2]
            axItem.title = store.isAccessibilityGranted
                ? "自动粘贴权限：已开启 ✓"
                : "开启自动粘贴权限..."
            let loginItem = menu.items[3]
            loginItem.state = store.launchAtLoginEnabled ? .on : .off
        }
    }
}

// MARK: - Entry Point

@main
struct ClipVApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

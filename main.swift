import AppKit
import SwiftUI
import IOKit.hid
import ApplicationServices

// Penlink – Treiber für Wacom Intuos3 A5 Wide (PTZ-631W, USB 056A:00B5) – läuft komplett im Benutzerbereich.
// Liest die Stiftdaten direkt per HID und erzeugt daraus Mausereignisse mit Druck und Neigung.
// Das Datenformat stammt aus dem Linux-Treiber (drivers/hid/wacom_wac.c, wacom_intuos_irq).

let vendorID = 0x056A
let productID = 0x00B5
let tabletMaxX = 54204.0
let tabletMaxY = 31750.0
let maxPressure = 1023.0
let tipThreshold = 10       // ab diesem Druck gilt die Spitze als aufgesetzt
let stillRadius = 1.0       // Ruhezone in Bildschirmpunkten gegen Zittern bei stillstehendem Stift

let debug = CommandLine.arguments.contains("--debug")
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Penlink.log")

func log(_ text: String) {
    guard debug else { return }
    let line = "\(Date()) \(text)\n"
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

// MARK: - Bildschirmzuordnung

/// Gespeicherte Auswahl: Name des Monitors, oder leer = alle Monitore.
var selectedScreenName: String {
    get { UserDefaults.standard.string(forKey: "screen") ?? "" }
    set { UserDefaults.standard.set(newValue, forKey: "screen") }
}

/// Genutzter Bereich der Tablet-Fläche, normiert auf 0…1 (Ursprung oben links).
var tabletArea: CGRect {
    get {
        let v = (UserDefaults.standard.string(forKey: "area") ?? "").split(separator: " ").compactMap { Double($0) }
        return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : CGRect(x: 0, y: 0, width: 1, height: 1)
    }
    set { UserDefaults.standard.set("\(newValue.minX) \(newValue.minY) \(newValue.width) \(newValue.height)", forKey: "area") }
}

/// Zielrechteck in globalen Quartz-Koordinaten (Ursprung oben links am Hauptmonitor).
func targetRect(for name: String = selectedScreenName) -> CGRect {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &count)
    let all = ids.prefix(Int(count))

    if let screen = NSScreen.screens.first(where: { $0.localizedName == name }),
       let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
        return CGDisplayBounds(id)
    }
    return all.map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
}

// MARK: - Ereignisse erzeugen

final class Pen {
    let source = CGEventSource(stateID: .hidSystemState)
    var inProximity = false
    var isEraser = false
    var tipDown = false
    var lowerDown = false       // unterer Seitenschalter = Rechtsklick
    var upperDown = false       // oberer Seitenschalter = Doppelklick
    var position = CGPoint.zero
    var settled = false         // false = nächste Position ohne Ruhezone übernehmen (nach Eintritt in Reichweite)
    var lastPressure = 0.0
    var lastClick = (time: 0.0, point: CGPoint.zero, count: 0)

    func proximity(enter: Bool) {
        guard let e = CGEvent(source: source) else { return }
        e.type = .tabletProximity
        e.setIntegerValueField(.tabletProximityEventVendorID, value: Int64(vendorID))
        e.setIntegerValueField(.tabletProximityEventTabletID, value: Int64(productID))
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: 1)
        e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 1)
        e.setIntegerValueField(.tabletProximityEventPointerType, value: isEraser ? 3 : 1)
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x0587)  // x, y, Knöpfe, Druck, Neigung
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
        e.post(tap: .cghidEventTap)
        inProximity = enter
        settled = false
    }

    func post(_ type: CGEventType, button: CGMouseButton, pressure: Double, tilt: CGPoint, raw: (Int, Int), clickState: Int = 0) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button) else { return }
        e.setIntegerValueField(.mouseEventSubtype, value: 1)   // Tablet-Punkt
        e.setDoubleValueField(.mouseEventPressure, value: pressure)
        e.setIntegerValueField(.tabletEventPointX, value: Int64(raw.0))
        e.setIntegerValueField(.tabletEventPointY, value: Int64(raw.1))
        e.setIntegerValueField(.tabletEventPointPressure, value: Int64(pressure * 65535))
        e.setDoubleValueField(.tabletEventTiltX, value: tilt.x)
        e.setDoubleValueField(.tabletEventTiltY, value: tilt.y)
        e.setIntegerValueField(.tabletEventDeviceID, value: 1)
        if clickState > 0 { e.setIntegerValueField(.mouseEventClickState, value: Int64(clickState)) }
        e.post(tap: .cghidEventTap)
    }

    /// Klickzähler für Doppelklicks mit der Spitze
    func nextClickState() -> Int {
        let now = ProcessInfo.processInfo.systemUptime
        let near = abs(position.x - lastClick.point.x) < 5 && abs(position.y - lastClick.point.y) < 5
        let count = (now - lastClick.time < NSEvent.doubleClickInterval && near) ? lastClick.count + 1 : 1
        lastClick = (now, position, count)
        return count
    }

    func handle(_ d: [UInt8]) {
        guard d.count >= 10, d[0] == 2 else { return }

        // Werkzeug kommt in Reichweite: Kennung enthält, ob Spitze oder Radierer
        if d[1] & 0xFC == 0xC0 {
            let toolID = (Int(d[2]) << 4) | (Int(d[3]) >> 4) | ((Int(d[7]) & 0x0F) << 16) | ((Int(d[8]) & 0xF0) << 8)
            isEraser = toolID & 0x0008 != 0
            log(String(format: "Werkzeug 0x%X (%@)", toolID, isEraser ? "Radierer" : "Stift"))
            proximity(enter: true)
            return
        }

        // Werkzeug verlässt die Reichweite: gedrückte Tasten loslassen
        if d[1] & 0xFE == 0x80 {
            let zero = CGPoint.zero
            if tipDown { post(.leftMouseUp, button: .left, pressure: 0, tilt: zero, raw: (0, 0)); tipDown = false }
            if lowerDown { post(.rightMouseUp, button: .right, pressure: 0, tilt: zero, raw: (0, 0)); lowerDown = false }
            upperDown = false
            proximity(enter: false)
            return
        }

        // Stiftdaten
        guard d[1] & 0xB8 == 0xA0 else { return }
        if !inProximity { proximity(enter: true) }

        let rawX = (Int(d[2]) << 9) | (Int(d[3]) << 1) | ((Int(d[9]) >> 1) & 1)
        let rawY = (Int(d[4]) << 9) | (Int(d[5]) << 1) | (Int(d[9]) & 1)
        let rawPressure = (Int(d[6]) << 2) | ((Int(d[7]) >> 6) & 3)
        let tiltX = Double(((Int(d[7]) << 1) & 0x7E) | (Int(d[8]) >> 7)) - 64
        let tiltY = Double(Int(d[8]) & 0x7F) - 64
        let tilt = CGPoint(x: tiltX / 64, y: tiltY / 64)
        let pressure = min(Double(rawPressure) / maxPressure, 1)

        let r = targetRect()
        let a = tabletArea
        let fx = min(max((Double(rawX) / tabletMaxX - a.minX) / a.width, 0), 1)
        let fy = min(max((Double(rawY) / tabletMaxY - a.minY) / a.height, 0), 1)
        let measured = CGPoint(x: r.minX + fx * (r.width - 1), y: r.minY + fy * (r.height - 1))

        // Ruhezone: Kleinstes Rauschen bei ruhendem Stift ignorieren. Sobald der Stift die Zone verlässt,
        // springt der Zeiger auf die exakt gemessene Position – die Genauigkeit bleibt also erhalten.
        let moved = !settled || hypot(measured.x - position.x, measured.y - position.y) >= stillRadius
        if moved { position = measured }
        settled = true

        let tip = rawPressure > tipThreshold
        let lower = d[1] & 0x02 != 0
        let upper = d[1] & 0x04 != 0
        let raw = (rawX, rawY)

        // Spitze
        if tip && !tipDown {
            post(.leftMouseDown, button: .left, pressure: pressure, tilt: tilt, raw: raw, clickState: nextClickState())
        } else if !tip && tipDown {
            post(.leftMouseUp, button: .left, pressure: 0, tilt: tilt, raw: raw, clickState: lastClick.count)
        }
        tipDown = tip

        // Unterer Seitenschalter: Rechtsklick
        if lower && !lowerDown {
            post(.rightMouseDown, button: .right, pressure: pressure, tilt: tilt, raw: raw, clickState: 1)
        } else if !lower && lowerDown {
            post(.rightMouseUp, button: .right, pressure: 0, tilt: tilt, raw: raw, clickState: 1)
        }
        lowerDown = lower

        // Oberer Seitenschalter: Doppelklick
        if upper && !upperDown {
            for n in 1...2 {
                post(.leftMouseDown, button: .left, pressure: 1, tilt: tilt, raw: raw, clickState: n)
                post(.leftMouseUp, button: .left, pressure: 0, tilt: tilt, raw: raw, clickState: n)
            }
        }
        upperDown = upper

        // Bewegung – nur senden, wenn sich etwas geändert hat (sonst halten Drag & Drop-Ziele nicht still)
        let pressureChanged = tipDown && abs(pressure - lastPressure) >= 0.01
        guard moved || pressureChanged else { return }
        lastPressure = pressure
        if tipDown {
            post(.leftMouseDragged, button: .left, pressure: pressure, tilt: tilt, raw: raw)
        } else if lowerDown {
            post(.rightMouseDragged, button: .right, pressure: pressure, tilt: tilt, raw: raw)
        } else {
            post(.mouseMoved, button: .left, pressure: 0, tilt: tilt, raw: raw)
        }
    }
}

// MARK: - USB/HID

final class Tablet {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
    let pen = Pen()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    var connected = false
    var onChange: () -> Void = {}

    func start() {
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: vendorID, kIOHIDProductIDKey: productID,
            kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: 2,
        ] as CFDictionary)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<Tablet>.fromOpaque(ctx!).takeUnretainedValue().attach(device)
        }, me)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, _ in
            let t = Unmanaged<Tablet>.fromOpaque(ctx!).takeUnretainedValue()
            t.connected = false
            log("Tablet getrennt")
            t.onChange()
        }, me)
        // "common modes": Stiftdaten auch verarbeiten, während ein Menü offen ist oder im Fenster gezogen wird
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, 0)
        log(String(format: "HID-Manager geöffnet: 0x%08X", result))
    }

    func attach(_ device: IOHIDDevice) {
        // Exklusiv öffnen, damit der eingebaute Maus-Modus den Zeiger nicht zusätzlich bewegt
        var result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        if result != kIOReturnSuccess { result = IOHIDDeviceOpen(device, 0) }
        log(String(format: "Gerät geöffnet: 0x%08X", result))

        // Tablet vom Maus-Modus in den Wacom-Modus umschalten (Feature-Report 2 = 2)
        var mode: [UInt8] = [2, 2]
        let setResult = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 2, &mode, mode.count)
        log(String(format: "Wacom-Modus: 0x%08X", setResult))

        IOHIDDeviceRegisterInputReportCallback(device, buffer, 64, { ctx, _, _, _, _, report, length in
            let data = Array(UnsafeBufferPointer(start: report, count: length))
            if debug { log(data.map { String(format: "%02x", $0) }.joined(separator: " ")) }
            Unmanaged<Tablet>.fromOpaque(ctx!).takeUnretainedValue().pen.handle(data)
        }, Unmanaged.passUnretained(self).toOpaque())

        connected = result == kIOReturnSuccess
        onChange()
    }
}

// MARK: - Bedienfeld

let tabletAspect = tabletMaxX / tabletMaxY

/// Seitenverhältnis des Ziels in normierten Tablet-Einheiten (Breite / Höhe)
func normalizedAspect(for name: String) -> Double {
    let r = targetRect(for: name)
    return (r.width / r.height) / tabletAspect
}

/// Passt die Höhe an das Seitenverhältnis des Monitors an (falls eingeschaltet) und hält die Fläche auf dem Tablet.
func fitted(_ r: CGRect, keepAspect: Bool = UserDefaults.standard.bool(forKey: "keepAspect"),
            screen: String = selectedScreenName) -> CGRect {
    guard keepAspect else { return r }
    let n = normalizedAspect(for: screen)
    var w = r.width, h = w / n
    if h > 1 { h = 1; w = n }
    if w > 1 { w = 1; h = 1 / n }
    let x = min(max(r.midX - w / 2, 0), 1 - w)
    let y = min(max(r.midY - h / 2, 0), 1 - h)
    return CGRect(x: x, y: y, width: w, height: h)
}

/// Änderungen sind zunächst nur ein Entwurf und gelten erst mit „OK“ –
/// sonst würde sich die Zuordnung ändern, während man den Rahmen mit dem Stift zieht.
struct SettingsView: View {
    let close: () -> Void
    @State var screen = selectedScreenName
    @State var keepAspect = UserDefaults.standard.bool(forKey: "keepAspect")
    @State var area = tabletArea
    @State var startArea: CGRect?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Monitor:", selection: $screen) {
                Text("Alle Monitore").tag("")
                ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 360)

            // Tablet-Gehäuse mit aktiver Fläche
            tablet
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(white: 0.12)))

            HStack {
                Toggle("Seitenverhältnis des Monitors beibehalten", isOn: $keepAspect)
                Spacer()
                Button("Ganze Fläche") { area = fit(CGRect(x: 0, y: 0, width: 1, height: 1)) }
            }
            HStack {
                Text("Den gestrichelten Rahmen verschieben oder an den Ecken ziehen.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen", action: close).keyboardShortcut(.cancelAction)
                Button("OK") {
                    selectedScreenName = screen
                    UserDefaults.standard.set(keepAspect, forKey: "keepAspect")
                    tabletArea = area
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 560)
        .onChange(of: screen) { _ in area = fit(area) }
        .onChange(of: keepAspect) { _ in area = fit(area) }
    }

    var tablet: some View {
        GeometryReader { geo in
            let size = geo.size
            let a = area
            let frame = CGRect(x: a.minX * size.width, y: a.minY * size.height,
                               width: a.width * size.width, height: a.height * size.height)
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.25))
                    .frame(width: size.width, height: size.height)
                    .position(x: size.width / 2, y: size.height / 2)

                // Zugeordnete Fläche: verschiebbar
                Rectangle().fill(Color.accentColor.opacity(0.18))
                    .overlay(Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5])))
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                    .gesture(DragGesture(coordinateSpace: .named("tablet"))
                        .onChanged { move($0.translation, in: size) }
                        .onEnded { _ in startArea = nil })

                // Aufteilung auf die einzelnen Monitore
                ForEach(monitorParts(), id: \.name) { part in
                    let r = CGRect(x: frame.minX + part.rect.minX * frame.width, y: frame.minY + part.rect.minY * frame.height,
                                   width: part.rect.width * frame.width, height: part.rect.height * frame.height)
                    Rectangle().stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                    Text(part.name).font(.caption).foregroundColor(.white)
                        .position(x: r.midX, y: r.midY)
                }
                .allowsHitTesting(false)

                // Ecken: Größe ändern
                ForEach(0..<4, id: \.self) { c in
                    Rectangle().fill(Color.white)
                        .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                        .frame(width: 11, height: 11)
                        .position(x: c % 2 == 0 ? frame.minX : frame.maxX, y: c < 2 ? frame.minY : frame.maxY)
                        .gesture(DragGesture(coordinateSpace: .named("tablet"))
                            .onChanged { resize(corner: c, $0.translation, in: size) }
                            .onEnded { _ in startArea = nil })
                }
            }
        }
        .coordinateSpace(name: "tablet")
        .aspectRatio(tabletAspect, contentMode: .fit)
    }

    func fit(_ r: CGRect) -> CGRect { fitted(r, keepAspect: keepAspect, screen: screen) }

    /// Monitore innerhalb des Ziels, normiert auf 0…1
    func monitorParts() -> [(name: String, rect: CGRect)] {
        let target = targetRect(for: screen)
        let screens = screen.isEmpty ? NSScreen.screens : NSScreen.screens.filter { $0.localizedName == screen }
        return screens.compactMap { s in
            guard let id = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            let b = CGDisplayBounds(id)
            return (s.localizedName, CGRect(x: (b.minX - target.minX) / target.width, y: (b.minY - target.minY) / target.height,
                                            width: b.width / target.width, height: b.height / target.height))
        }
    }

    func move(_ t: CGSize, in size: CGSize) {
        if startArea == nil { startArea = area }
        let s = startArea!
        area = CGRect(x: min(max(s.minX + t.width / size.width, 0), 1 - s.width),
                      y: min(max(s.minY + t.height / size.height, 0), 1 - s.height),
                      width: s.width, height: s.height)
    }

    /// Ecke 0 = oben links, 1 = oben rechts, 2 = unten links, 3 = unten rechts; die gegenüberliegende Ecke bleibt stehen.
    func resize(corner c: Int, _ t: CGSize, in size: CGSize) {
        if startArea == nil { startArea = area }
        let s = startArea!
        let left = c % 2 == 0, top = c < 2
        let anchor = CGPoint(x: left ? s.maxX : s.minX, y: top ? s.maxY : s.minY)
        let px = min(max((left ? s.minX : s.maxX) + t.width / size.width, 0), 1)
        let py = min(max((top ? s.minY : s.maxY) + t.height / size.height, 0), 1)
        let minSize = 0.05
        var w = max(left ? anchor.x - px : px - anchor.x, minSize)
        var h = max(top ? anchor.y - py : py - anchor.y, minSize)
        if keepAspect {
            let n = normalizedAspect(for: screen)
            let maxW = left ? anchor.x : 1 - anchor.x
            let maxH = top ? anchor.y : 1 - anchor.y
            h = w / n
            if h > maxH { h = maxH; w = h * n }
            if w > maxW { w = maxW; h = w / n }
        }
        area = CGRect(x: left ? anchor.x - w : anchor.x, y: top ? anchor.y - h : anchor.y, width: w, height: h)
    }
}

// MARK: - Menüleiste

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let tablet = Tablet()
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["keepAspect": true])
        if UserDefaults.standard.string(forKey: "area") == nil {
            tabletArea = fitted(CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "pencil.tip.crop.circle", accessibilityDescription: "Penlink")
        statusItem.menu = NSMenu()
        statusItem.menu!.delegate = self

        // Rechte: Eingabeüberwachung (Tablet lesen) und Bedienungshilfen (Zeiger steuern)
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)

        log("Eingabeüberwachung: \(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted), Bedienungshilfen: \(AXIsProcessTrusted())")
        tablet.onChange = { [weak self] in self?.updateIcon() }
        tablet.start()
        updateIcon()
    }

    func updateIcon() {
        statusItem.button?.appearsDisabled = !tablet.connected
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: tablet.connected ? "Intuos3 verbunden" : "Intuos3 nicht gefunden", action: nil, keyEquivalent: "")
        if !AXIsProcessTrusted() {
            menu.addItem(withTitle: "⚠︎ Bedienungshilfen-Recht fehlt", action: nil, keyEquivalent: "")
        }
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            menu.addItem(withTitle: "⚠︎ Eingabeüberwachungs-Recht fehlt", action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Tablet-Fläche zuordnen zu:", action: nil, keyEquivalent: "")

        var names = NSScreen.screens.map { $0.localizedName }
        if !names.contains(selectedScreenName) && !selectedScreenName.isEmpty { selectedScreenName = "" }
        names.insert("", at: 0)
        for name in names {
            let item = NSMenuItem(title: name.isEmpty ? "Alle Monitore" : name, action: #selector(choose(_:)), keyEquivalent: "")
            item.representedObject = name
            item.target = self
            item.indentationLevel = 1
            item.state = name == selectedScreenName ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Tablet-Fläche einstellen …", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc func choose(_ sender: NSMenuItem) {
        selectedScreenName = sender.representedObject as? String ?? ""
        tabletArea = fitted(tabletArea)
    }

    var settingsWindow: NSWindow?

    @objc func openSettings() {
        if settingsWindow?.isVisible != true {
            let controller = NSHostingController(rootView: SettingsView(close: { [weak self] in self?.settingsWindow?.close() }))
            controller.sizingOptions = [.minSize]      // Fenstergröße nicht an den Inhalt anpassen, nur Mindestgröße
            let w = NSWindow(contentViewController: controller)
            w.styleMask.insert(.resizable)
            w.title = "Penlink – Tablet-Fläche"
            w.isReleasedWhenClosed = false
            w.setContentSize(settingsWindow?.contentLayoutRect.size ?? NSSize(width: 960, height: 720))
            if let old = settingsWindow { w.setFrameOrigin(old.frame.origin) } else { w.center() }
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow!.makeKeyAndOrderFront(nil)
    }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

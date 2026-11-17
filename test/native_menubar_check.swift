import AppKit
import SwiftUI

/// Consumes data emitted by menubar_test.dart, then renders the production view.
@main
struct NativeMenuCheck {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Usage: native-menu-check <controller-fixture.json> <snapshot-directory>")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let catalogURL = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("native-app-catalog-fixture.json")
        let catalogs = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as! [String: Any]
        let state = try NativeMenuState.decode(fixture)
        precondition(state.initialized && state.currentProfile?.name == "VLESS")
        precondition(state.currentServer?.name == "🇳🇴 Норвегия")
        precondition(state.currentServer?.delay == 135)
        precondition(state.runtimeRules.count == 4 && state.sites.count == 2)
        precondition(state.routes[0].paths[0].result == "118 мс")
        precondition(state.routes[1].paths[0].result == "Тайм-аут")
        var incompatible = fixture
        incompatible["protocolVersion"] = 99
        do {
            _ = try NativeMenuState.decode(incompatible)
            preconditionFailure("An incompatible protocol must be rejected")
        } catch MenuContractError.version {}
        var incomplete = fixture
        incomplete.removeValue(forKey: "groups")
        do {
            _ = try NativeMenuState.decode(incomplete)
            preconditionFailure("Missing controller state must be rejected")
        } catch is DecodingError {}

        let model = NativeMenuModel()
        var presented = false
        model.onPresentation = { presented = $0 }
        try model.receive(fixture)
        precondition(presented)
        model.legacy(["revision": state.revision + 2, "visible": true])
        precondition(!presented)
        try model.receive(fixture)
        precondition(!presented, "A stale action response must not hide a legacy editor")
        var newer = fixture
        newer["revision"] = state.revision + 3
        try model.receive(newer)
        precondition(presented)
        model.transport = { method, args, completion in
            precondition(method == "action" && args?["action"] as? String == "route")
            precondition(args?["service"] as? String == "YouTube")
            precondition(args?["value"] as? String == "vpn")
            completion(NativeMenuFailure(message: "Service unavailable"))
        }
        var saved = true
        model.send("route", value: "vpn", fields: ["service": "YouTube"]) { saved = $0 }
        precondition(!saved && model.busy.isEmpty && model.message == "Service unavailable")
        print("Native contract, presentation ordering and command errors passed")

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let directory = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for appearance in ["light", "dark"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            for width in [375, 320] {
                for page in ["home", "vpn", "zapret", "routes", "settings", "advanced", "application", "appPicker", "processes", "longRoutes"] {
                    let model = NativeMenuModel()
                    var snapshot = fixture
                    snapshot["page"] = ["advanced", "application"].contains(page) ? "settings" : ["appPicker", "processes", "longRoutes"].contains(page) ? "routes" : page
                    snapshot["appearance"] = appearance
                    if page == "longRoutes" {
                        snapshot["sites"] = (1...30).map { ["id": "example\($0).com", "name": "example\($0).com", "route": "vpn", "target": "VPN"] }
                    }
                    try model.receive(snapshot)
                    var actions = [[String: Any]]()
                    model.transport = { method, args, completion in
                        if method == "action", let args { actions.append(args) }
                        if method == "appCatalog" { completion(catalogs[args?["kind"] as? String ?? "apps"]) }
                        else if method == "processPattern" { completion(catalogs["pattern"]) }
                        else { completion(snapshot) }
                    }
                    let size = NSSize(width: width, height: 600)
                    let detail = ["advanced", "application"].contains(page) ? page : ["appPicker", "processes"].contains(page) ? "appPicker" : ""
                    let root: AnyView = page == "processes"
                        ? AnyView(NativeAppPicker(model: model, cancel: {}, manual: {}, kind: "processes").padding(12).frame(width: CGFloat(width), height: 600).background(MenuPalette.adaptive(0xf1f3f5, 0x242629)).preferredColorScheme(appearance == "dark" ? .dark : .light))
                        : AnyView(NativeMenuView(model: model, width: CGFloat(width), detail: detail))
                    let host = NSHostingView(rootView: root)
                    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
                    window.contentView = host
                    host.frame = NSRect(origin: .zero, size: size)
                    window.layoutIfNeeded()
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                    if page == "longRoutes" {
                        func scrollViews(_ view: NSView) -> [NSScrollView] {
                            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
                        }
                        let scrolls = scrollViews(host)
                        precondition(!scrolls.isEmpty)
                        for scroll in scrolls {
                            scroll.scrollerStyle = .legacy
                            precondition(!scroll.hasVerticalScroller && !scroll.hasHorizontalScroller, "The popover must not reserve a scrollbar gutter")
                            if let document = scroll.documentView, document.bounds.height > scroll.contentView.bounds.height {
                                scroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
                                precondition(scroll.contentView.bounds.origin.y == 80, "Long rule lists must remain scrollable")
                                scroll.contentView.scroll(to: .zero)
                            }
                        }
                    }
                    if page == "vpn" {
                        // Local window events exercise the real Button hit regions.
                        // No global mouse events or running VPN services are used.
                        window.orderBack(nil)
                        var actions = [[String: Any]]()
                        model.transport = { _, args, completion in
                            if let args { actions.append(args) }
                            completion(snapshot)
                        }
                        let clicks: [(CGFloat, CGFloat, String, String)] = [
                            (48, 25, "navigate", "home"), // Icon, positive control.
                            (18, 35, "navigate", "home"), // Blank edge of an inactive tab.
                            (40, 299, "server", "🇳🇴 Норвегия"),
                            (CGFloat(width) / 2, 360, "server", "🇫🇮 Финляндия"), // Empty row space.
                        ]
                        for (x, y, action, value) in clicks {
                            actions.removeAll()
                            let point = host.convert(NSPoint(x: x, y: host.isFlipped ? y : 600 - y), to: nil)
                            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                                NSApp.sendEvent(event)
                            }
                            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                            guard actions.count == 1, actions[0]["action"] as? String == action, actions[0]["value"] as? String == value else {
                                fputs("Native hit check failed: \(action) at (\(x), \(y)), width \(width), \(appearance); received \(actions)\n", stderr)
                                exit(1)
                            }
                        }
                        window.orderOut(nil)
                    }
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No native bitmap") }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG data") }
                    try png.write(to: directory.appendingPathComponent("\(page)-\(width)-\(appearance).png"))
                    if page == "appPicker" || page == "processes" {
                        window.orderBack(nil)
                        let rows: [CGFloat] = page == "appPicker" ? [218] : [155, 211]
                        for point in rows.map({ NSPoint(x: CGFloat(width) / 2, y: $0) }) + [NSPoint(x: CGFloat(width) - 45, y: 578)] {
                            let location = host.convert(NSPoint(x: point.x, y: host.isFlipped ? point.y : 600 - point.y), to: nil)
                            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
                            }
                            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
                        }
                        let expected = page == "appPicker" ? ["/Applications/Example.app"] : ["codex", "codex-helper"]
                        guard actions.count == 1, actions[0]["action"] as? String == "saveApps", actions[0]["value"] as? [String] == expected else {
                            fputs("Native picker save failed for \(page), width \(width), \(appearance): \(actions)\n", stderr); exit(1)
                        }
                        window.orderOut(nil)
                    }
                    window.contentView = nil
                }
            }
        }
        print("Rendered 40 production SwiftUI snapshots, including app/process selection, all settings and long rules")
        print("Long rules remain scrollable without scrollbar gutters, including legacy scroller style")
        print("Native clicks on icons, tab padding and server row whitespace passed")
        print("Native application selection, process multiselection and save actions passed")
    }
}

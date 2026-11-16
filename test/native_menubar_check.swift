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
                for page in ["home", "vpn", "zapret", "routes", "settings"] {
                    let model = NativeMenuModel()
                    var snapshot = fixture
                    snapshot["page"] = page
                    snapshot["appearance"] = appearance
                    try model.receive(snapshot)
                    let size = NSSize(width: width, height: 600)
                    let host = NSHostingView(rootView: NativeMenuView(model: model, width: CGFloat(width)))
                    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
                    window.contentView = host
                    host.frame = NSRect(origin: .zero, size: size)
                    window.layoutIfNeeded()
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No native bitmap") }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG data") }
                    try png.write(to: directory.appendingPathComponent("\(page)-\(width)-\(appearance).png"))
                    window.contentView = nil
                }
            }
        }
        print("Rendered 20 production SwiftUI snapshots at 375 and 320 pt, light and dark")
    }
}

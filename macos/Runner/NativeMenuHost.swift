import AppKit
import SwiftUI
import FlutterMacOS

/// Keeps the existing engine and plugins alive, with SwiftUI as the main surface.
/// Import, profile management and advanced editors retain their existing routes.
final class NativeMenuHost: NSViewController {
    let model: NativeMenuModel
    private let flutter: FlutterViewController
    private let hosting: NSHostingController<NativeMenuView>
    private let channel: FlutterMethodChannel
    private var attachTimer: Timer?
    private var didReportReady = false

    init(flutter: FlutterViewController) {
        let model = NativeMenuModel()
        self.model = model
        self.flutter = flutter
        channel = FlutterMethodChannel(name: "customvpn/menubar", binaryMessenger: flutter.engine.binaryMessenger)
        hosting = NSHostingController(rootView: NativeMenuView(model: model))
        super.init(nibName: nil, bundle: nil)
        model.transport = { [weak self] method, args, completion in
            self?.channel.invokeMethod(method, arguments: args) { result in
                if let error = result as? FlutterError {
                    completion(NativeMenuFailure(message: error.message ?? error.code))
                } else if let result, (result as AnyObject) === (FlutterMethodNotImplemented as AnyObject) {
                    completion(NativeMenuFailure(message: "Контроллер интерфейса ещё не готов"))
                } else { completion(result) }
            }
        }
        model.onPresentation = { [weak self] native in
            guard let self else { return }
            self.flutter.view.isHidden = native
            self.hosting.view.isHidden = !native
            if native && !self.didReportReady {
                self.didReportReady = true
                NSLog("CustomVPN SwiftUI menu ready; protocol=1")
            }
        }
        channel.setMethodCallHandler { [weak self] call, reply in
            guard let self else { reply(nil); return }
            switch call.method {
            case "state":
                do { if let args = call.arguments { try self.model.receive(args); self.attachTimer?.invalidate(); self.attachTimer = nil } }
                catch { self.model.message = "Ошибка канала интерфейса: \(error.localizedDescription)" }
            case "notice": self.model.message = call.arguments as? String
            case "legacyVisible": if let args = call.arguments as? [String: Any] { self.model.legacy(args) }
            default: reply(FlutterMethodNotImplemented); return
            }
            reply(nil)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 375, height: 600))
        for child in [flutter as NSViewController, hosting as NSViewController] {
            addChild(child)
            child.view.frame = view.bounds
            child.view.autoresizingMask = [.width, .height]
            view.addSubview(child.view)
        }
        hosting.view.isHidden = true
        attachTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.attach() }
        attach()
    }
    private func attach() {
        channel.invokeMethod("attach", arguments: nil) { [weak self] result in
            guard let self, let result, !(result is FlutterError), (result as AnyObject) !== (FlutterMethodNotImplemented as AnyObject) else { return }
            do {
                try self.model.receive(result)
                self.attachTimer?.invalidate(); self.attachTimer = nil
            } catch { self.model.message = "Ошибка канала интерфейса: \(error.localizedDescription)" }
        }
    }
    func opened() { model.refresh(opened: true) }
    deinit { attachTimer?.invalidate() }
}

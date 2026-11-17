import Foundation
import SwiftUI

/// Versioned data from the existing Dart controller. No network state is inferred in SwiftUI.
struct NativeMenuState: Decodable {
    let protocolVersion, revision: Int
    let initialized, legacyVisible: Bool
    let page: String
    let vpnRunning, vpnBusy: Bool
    let elapsed: String
    let zapretAvailable, zapretKnown, zapretRunning, zapretBusy: Bool
    let mode: String
    let systemProxy, tun, automatic, rulesBusy, routeBusy, nodeBusy, checking, testing: Bool
    let progress, strategy, strategyTitle, ipset: String
    let strategies: [MenuOption]
    let scores: [MenuScore]
    let best: [String]
    let checks: [MenuCheck]
    let currentProfileId: String?
    let profiles: [MenuProfile]
    let groups: [MenuGroup]
    let routes: [MenuServiceRoute]
    let sites, apps: [MenuRule]
    let onlyListed: Bool
    let runtimeRules: [MenuRuntimeRule]
    let accent: UInt32?
    let appearance: String
    let autoLaunch: Bool
    let startPage: String
    let application: [String: Bool]
    let locale: String?
    let locales, tools: [MenuOption]

    var currentProfile: MenuProfile? { profiles.first { $0.id == currentProfileId } }
    var currentServer: MenuServer? { groups.flatMap(\.servers).first { $0.selected } }
    static func decode(_ value: Any) throws -> Self {
        let data = try JSONSerialization.data(withJSONObject: value)
        let state = try JSONDecoder().decode(Self.self, from: data)
        guard state.protocolVersion == 1 else { throw MenuContractError.version }
        guard Set(state.application.keys) == ["autoRun", "silentLaunch", "autoCheckUpdate", "overrideProviderSettings", "closeConnections", "minimizeOnExit", "openLogs", "isAnimateToPage", "zashboardInApp"] else { throw MenuContractError.settings }
        return state
    }
}
struct MenuOption: Decodable, Identifiable { let id, name: String }
struct MenuScore: Decodable { let name, score: String }
struct MenuCheck: Decodable { let name, result: String }
struct MenuProfile: Decodable, Identifiable {
    let id, name: String
    let updating: Bool
    let usage: String?
    let fraction: Double?
    let expires: String
    let updated: String?
}
struct MenuGroup: Decodable, Identifiable {
    let id: String
    let selectable: Bool
    let servers: [MenuServer]
}
struct MenuServer: Decodable {
    let name, type: String
    let selected: Bool
    let delay: Int?
}
struct MenuServiceRoute: Decodable { let name: String; let paths: [MenuPath] }
struct MenuPath: Decodable, Identifiable {
    let id, name: String
    let available, selected, selectable: Bool
    let result: String
}
struct MenuRule: Decodable, Identifiable { let id, name, route, target: String }
struct MenuRuntimeRule: Decodable { let name, type, target: String }
enum MenuContractError: LocalizedError {
    case version
    case settings
    var errorDescription: String? {
        switch self {
        case .version: return "Несовместимая версия канала интерфейса"
        case .settings: return "Неполный набор настроек приложения"
        }
    }
}

final class NativeMenuModel: ObservableObject {
    @Published private(set) var state: NativeMenuState?
    @Published private(set) var busy = Set<String>()
    @Published var message: String?
    var transport: ((String, [String: Any]?, @escaping (Any?) -> Void) -> Void)?
    var onPresentation: ((Bool) -> Void)?
    private var revision = -1

    func request<T: Decodable>(_ method: String, args: [String: Any], as type: T.Type, completion: @escaping (Result<T, Error>) -> Void) {
        guard let transport else { completion(.failure(NativeMenuFailure(message: "Контроллер не подключён"))); return }
        transport(method, args) { result in
            do {
                if let error = result as? NativeMenuFailure { throw error }
                guard let result else { throw NativeMenuFailure(message: "Контроллер не вернул данные") }
                let data = try JSONSerialization.data(withJSONObject: result)
                completion(.success(try JSONDecoder().decode(T.self, from: data)))
            } catch { completion(.failure(error)) }
        }
    }

    func receive(_ value: Any) throws {
        let incoming = try NativeMenuState.decode(value)
        guard incoming.revision >= revision else { return }
        revision = incoming.revision
        state = incoming
        onPresentation?(incoming.initialized && !incoming.legacyVisible)
    }
    func legacy(_ value: [String: Any]) {
        guard let next = value["revision"] as? Int, let visible = value["visible"] as? Bool, next >= revision else { return }
        revision = next
        onPresentation?(state?.initialized == true && !visible)
    }
    func refresh(opened: Bool = false) {
        transport?(opened ? "opened" : "state", nil) { [weak self] result in
            self?.accept(result)
        }
    }
    private func accept(_ result: Any?) {
        guard let result else { message = "Контроллер интерфейса не вернул состояние"; return }
        if let error = result as? NativeMenuFailure { message = error.message; return }
        do { try receive(result) }
        catch { message = "Не удалось прочитать состояние: \(error.localizedDescription)" }
    }
    func send(_ action: String, value: Any? = nil, fields: [String: Any] = [:], completion: ((Bool) -> Void)? = nil) {
        guard let transport else { message = "Контроллер интерфейса не подключён"; completion?(false); return }
        guard !busy.contains(action) else { return }
        busy.insert(action)
        message = nil
        var args = fields
        args["action"] = action
        if let value { args["value"] = value }
        transport("action", args) { [weak self] result in
            guard let self else { return }
            self.busy.remove(action)
            if let error = result as? NativeMenuFailure {
                self.message = error.message; completion?(false); return
            }
            self.accept(result)
            completion?(self.message == nil)
        }
    }
}
struct NativeMenuFailure: LocalizedError { let message: String; var errorDescription: String? { message } }

struct MenuAppEntry: Decodable, Identifiable {
    let name, path: String
    let network: Bool
    var id: String { path }
}
struct MenuAppCatalog: Decodable { let items: [MenuAppEntry] }
struct MenuProcessPattern: Decodable { let pattern: String; let values, matches, extra: [String]; let error: String? }

enum MenuPalette {
    static let accents: [(String, UInt32, UInt32)] = [
        ("Мятный", 0xffa4d7bd, 0x08766c), ("Синий", 0xffa6d0fc, 0x2866b3),
        ("Сиреневый", 0xffc4b5fa, 0x7252a2), ("Розовый", 0xfff0a5bc, 0xa63f76),
        ("Оранжевый", 0xfff2b078, 0xa44b08)
    ]
    static func color(_ argb: UInt32?) -> Color {
        guard let argb else { return Color(nsColor: .controlAccentColor) }
        let light = accents.first { $0.1 == argb }?.2 ?? argb
        return adaptive(light, argb)
    }
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

import SwiftUI
import AppKit

struct NativeMenuView: View {
    @ObservedObject var model: NativeMenuModel
    var width: CGFloat = 375
    @State private var detail = ""
    @State private var query = ""
    @State private var draftName = ""
    @State private var draftRoute = "vpn"
    @State private var previousRule: String?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let pages = [("home", "Главная", "house"), ("vpn", "VPN", "globe"), ("zapret", "Zapret", "shield.lefthalf.filled"), ("routes", "Маршруты", "point.3.connected.trianglepath.dotted"), ("settings", "Настройки", "gearshape")]
    private var accent: Color { MenuPalette.color(model.state?.accent) }

    var body: some View {
        VStack(spacing: 0) {
            if let state = model.state {
                navigation(state)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch detail {
                        case "rules": allRules(state)
                        case "profiles": profiles(state)
                        case "site", "app": ruleEditor(state)
                        default:
                            switch state.page {
                            case "home": home(state)
                            case "vpn": vpn(state)
                            case "zapret": zapret(state)
                            case "routes": routing(state)
                            case "settings": settings(state)
                            default: EmptyView()
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 16)
                }
            } else {
                Spacer()
                ProgressView()
                Text("Подключение к контроллеру…").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 10)
                Spacer()
            }
            if let message = model.message {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(message).font(.system(size: 11)).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button { model.message = nil } label: { Image(systemName: "xmark").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).help("Закрыть сообщение").accessibilityLabel("Закрыть сообщение")
                }.padding(10).background(Color(nsColor: .controlBackgroundColor)).accessibilityAddTraits(.updatesFrequently)
            }
        }.frame(width: width, height: 600)
            .font(.system(size: 13)).tint(accent)
            .background(MenuPalette.adaptive(0xf1f3f5, 0x242629))
            .preferredColorScheme(model.state?.appearance == "dark" ? .dark : model.state?.appearance == "light" ? .light : nil)
            .onChange(of: model.state?.page) { _ in detail = "" }
    }
    private func navigation(_ s: NativeMenuState) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                Button { detail = ""; model.send("navigate", value: page.0) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: page.2).font(.system(size: 17))
                        Text(page.1).font(.system(size: width <= 320 ? 9 : 10, weight: s.page == page.0 ? .semibold : .regular)).lineLimit(1)
                    }.frame(maxWidth: .infinity).frame(height: 44)
                        .contentShape(Rectangle())
                        .foregroundStyle(s.page == page.0 ? accent : .secondary)
                        .background(s.page == page.0 ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).help(page.1).accessibilityLabel(page.1)
                    .accessibilityAddTraits(s.page == page.0 ? .isSelected : [])
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .option)
            }
        }.padding(4)
            .background(RoundedRectangle(cornerRadius: 17).fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor)) : AnyShapeStyle(.regularMaterial)))
            .padding(.horizontal, 10).padding(.top, 10)
    }
    private func small(_ text: String) -> some View { Text(text).font(.system(size: 11)).foregroundStyle(.secondary) }
    private func iconButton(_ symbol: String, _ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 17, height: 17) }.buttonStyle(.bordered).controlSize(.small).disabled(disabled).help(title).accessibilityLabel(title)
    }
    private func toggle(_ title: String, value: Bool, action: String, disabled: Bool = false) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: { model.send(action, value: $0) }))
            .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(disabled || model.busy.contains(action)).accessibilityLabel(title)
    }
    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 6) { Text(title); Spacer(minLength: 4); control() }.frame(minHeight: 39)
    }
    private func heading<Action: View>(_ title: String, @ViewBuilder action: () -> Action) -> some View {
        HStack { Text(title).font(.system(size: 12, weight: .semibold)); Spacer(minLength: 4); action() }
    }
    private func back(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { detail = "" } label: { Label("Назад", systemImage: "chevron.left").font(.system(size: 12)).contentShape(Rectangle()) }.buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
            Text(title).font(.system(size: 14, weight: .semibold))
        }
    }
    private func home(_ s: NativeMenuState) -> some View {
        Group {
            HStack(spacing: 8) {
                servicePad("VPN", symbol: "globe", on: s.vpnRunning, status: s.vpnBusy ? "Применяю…" : s.vpnRunning ? "Включён" : "Выключен", subtitle: s.vpnRunning ? [s.elapsed, s.currentServer?.name].compactMap { $0 }.joined(separator: " · ") : "Соединение остановлено", disabled: s.vpnBusy || s.currentProfile == nil, action: "vpn")
                servicePad("Zapret", symbol: "shield.lefthalf.filled", on: s.zapretRunning, status: !s.zapretAvailable ? "Не установлен" : !s.zapretKnown ? "Проверяю…" : s.zapretBusy ? "Применяю…" : s.zapretRunning ? "Включён" : "Выключен", subtitle: s.strategyTitle, disabled: !s.zapretAvailable || !s.zapretKnown || s.zapretBusy || s.testing, action: "zapret")
            }
            profile(s)
            MenuModeSelector(mode: s.mode, enabled: !model.busy.contains("mode")) { model.send("mode", value: $0) }.frame(height: 24)
            HStack {
                HStack { Text("System Proxy").font(.system(size: 11)); Spacer(minLength: 2); toggle("System Proxy", value: s.systemProxy, action: "systemProxy") }
                Spacer(minLength: 14)
                HStack { Text("TUN").font(.system(size: 11)); Spacer(minLength: 2); toggle("TUN", value: s.tun, action: "tun") }
            }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            routeControls(s)
        }
    }
    private func servicePad(_ title: String, symbol: String, on: Bool, status: String, subtitle: String, disabled: Bool, action: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(accent).frame(width: 32, height: 32).background(Color(nsColor: .controlBackgroundColor), in: Circle())
                Spacer(minLength: 3); toggle(title, value: on, action: action, disabled: disabled)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(status).font(.system(size: 11))
                Text(subtitle).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).help(subtitle)
            }
        }.padding(width <= 320 ? 10 : 12).frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? accent.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }
    private func profile(_ s: NativeMenuState) -> some View {
        group {
            if let p = s.currentProfile {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        small("Профиль")
                        Menu {
                            ForEach(s.profiles) { item in
                                Section {
                                    Button { model.send("profile", value: item.id) } label: {
                                        if item.id == p.id { Label(item.name, systemImage: "checkmark") } else { Text(item.name) }
                                    }
                                    if let usage = item.usage { Text(usage) }
                                    Text(item.expires)
                                    if let updated = item.updated { Text("Обновлён \(updated)") }
                                    Button("Обновить \(item.name)") { model.send("updateProfile", value: item.id) }.disabled(item.updating)
                                }
                            }
                            Divider()
                            Button("Обновить все") { model.send("updateAll") }.disabled(s.profiles.contains { $0.updating })
                            Button("Добавить профиль…") { model.send("addProfile") }
                            Button("Управление профилями…") { detail = "profiles" }
                        } label: { Text(p.name).font(.system(size: 15, weight: .semibold)).lineLimit(1) }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true).help("Выбрать профиль")
                    }
                    Spacer(minLength: 4)
                    iconButton("arrow.clockwise", "Обновить активный профиль", disabled: p.updating || model.busy.contains("updateProfile")) { model.send("updateProfile", value: p.id) }
                }.padding(.bottom, 10)
                profileUsage(p)
            } else {
                Button { model.send("addProfile") } label: { Label("Добавить профиль", systemImage: "plus") }.buttonStyle(.bordered)
            }
        }
    }
    private func profileUsage(_ p: MenuProfile) -> some View {
        VStack(spacing: 6) {
            if let usage = p.usage { HStack { Text(usage).monospacedDigit(); Spacer(minLength: 0) }.font(.system(size: 11)) }
            if let fraction = p.fraction {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                        Capsule().fill(accent).frame(width: g.size.width * min(1, max(0, fraction)))
                    }
                }.frame(height: 4).accessibilityLabel("Расход трафика").accessibilityValue(p.usage ?? "")
            }
            HStack { small(p.expires); Spacer(minLength: 3); small(p.updating ? "Обновление…" : p.updated.map { "Обновлён \($0)" } ?? "Не обновлён") }.font(.system(size: 10))
        }
    }
    private func routeControls(_ s: NativeMenuState) -> some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) { Text("Автовыбор").font(.system(size: 12, weight: .semibold)); small("Zapret → VPN") }
                Spacer(minLength: 3)
                toggle("Автовыбор", value: s.automatic, action: "automatic", disabled: s.rulesBusy)
                iconButton(s.routeBusy ? "xmark" : "waveform.path.ecg", s.routeBusy ? "Отменить проверку путей" : "Проверить пути", disabled: s.testing || s.rulesBusy) { model.send("pingRoutes") }
            }
            ForEach(s.routes, id: \.name) { route in
                HStack(spacing: 4) {
                    Label(route.name, systemImage: route.name == "YouTube" ? "play.rectangle.fill" : "gamecontroller.fill")
                        .font(.system(size: 11)).frame(width: width <= 320 ? 72 : 78, alignment: .leading)
                    ForEach(route.paths) { path in
                        Button { model.send("route", value: path.id, fields: ["service": route.name]) } label: {
                            HStack(spacing: 2) {
                                Text(path.name).font(.system(size: 10)); Spacer(minLength: 0)
                                Text(path.result).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                            }.padding(.horizontal, 5).frame(maxWidth: .infinity).frame(height: 31)
                                .contentShape(Rectangle())
                                .background(path.selected ? accent.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(path.selected ? accent : Color(nsColor: .separatorColor), lineWidth: path.selected ? 1.5 : 0.7) }
                                .opacity(path.available ? 1 : 0.4)
                        }.buttonStyle(.plain).disabled(!path.selectable || model.busy.contains("route"))
                            .accessibilityLabel("\(route.name): \(path.name), \(path.result)").accessibilityAddTraits(path.selected ? .isSelected : [])
                    }
                }
            }
            if s.mode != "rule" {
                HStack {
                    small(s.mode == "direct" ? "Трафик идёт напрямую." : "Весь трафик использует VPN.")
                    Spacer(minLength: 0); Button("By rule") { model.send("mode", value: "rule") }.controlSize(.small)
                }
            }
        }
    }
    private func vpn(_ s: NativeMenuState) -> some View {
        Group {
            row("VPN") { small(s.vpnBusy ? "Применяю…" : s.vpnRunning ? s.elapsed : "Выключен"); toggle("VPN", value: s.vpnRunning, action: "vpn", disabled: s.vpnBusy || s.currentProfile == nil) }
            profile(s)
            if s.groups.isEmpty { small("В выбранном профиле нет серверов.") }
            ForEach(s.groups) { g in
                VStack(spacing: 7) {
                    heading(s.groups.count == 1 ? "Серверы" : g.id) {
                        Button(s.nodeBusy ? "Проверяю…" : "Пинг всех") { model.send("pingNodes") }.controlSize(.small).disabled(s.nodeBusy)
                    }
                    ForEach(Array(g.servers.enumerated()), id: \.offset) { _, node in
                        Button { model.send("server", value: node.name, fields: ["group": g.id]) } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) { Text(node.name).font(.system(size: 13)).lineLimit(1); small(node.type) }
                                Spacer(minLength: 3)
                                Text(s.nodeBusy || node.delay == nil || node.delay == 0 ? "…" : node.delay! < 0 ? "Тайм-аут" : "\(node.delay!) мс")
                                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(node.delay.map { $0 < 0 } == true ? MenuPalette.adaptive(0x955216, 0xefba7b) : MenuPalette.adaptive(0x26743b, 0x91d6a2))
                                if node.selected { Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(accent) }
                            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .background(node.selected ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(node.selected ? accent : .clear, lineWidth: 1.5) }
                        }.buttonStyle(.plain).disabled(!g.selectable || model.busy.contains("server")).help(node.name).accessibilityAddTraits(node.selected ? .isSelected : [])
                    }
                }
            }
        }
    }
    private func zapret(_ s: NativeMenuState) -> some View {
        Group {
            row("Zapret") { small(!s.zapretAvailable ? "Не установлен" : !s.zapretKnown ? "Проверяю…" : s.zapretRunning ? "Включён" : "Выключен"); toggle("Zapret", value: s.zapretRunning, action: "zapret", disabled: !s.zapretAvailable || !s.zapretKnown || s.zapretBusy || s.testing) }
            group {
                row("Стратегия") {
                    Picker("Стратегия", selection: Binding(get: { s.strategy }, set: { model.send("strategy", value: $0) })) { ForEach(s.strategies) { Text($0.name).tag($0.id) } }.labelsHidden().controlSize(.small).frame(maxWidth: 190).disabled(s.zapretBusy || s.testing)
                }; Divider()
                row("IPSet") {
                    Picker("IPSet", selection: Binding(get: { s.ipset }, set: { model.send("ipset", value: $0) })) { Text("Домены и правила").tag("none"); Text("Загруженный IPSet").tag("loaded"); Text("Любые адреса").tag("any") }.labelsHidden().controlSize(.small).frame(maxWidth: 180).disabled(s.zapretBusy || s.testing)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                heading("Списки доменов и IP") { Button("Открыть") { model.send("openLists") }.controlSize(.small) }
                HStack {
                    Button("Применить списки") { model.send("applyLists") }
                    Button("Обновить стратегии") { model.send("updateStrategies") }
                }.buttonStyle(.bordered).controlSize(.small).disabled(s.zapretBusy || s.testing)
            }
            VStack(alignment: .leading, spacing: 10) {
                heading("Подключения") { EmptyView() }
                HStack {
                    ForEach(s.checks, id: \.name) { check in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(check.name, systemImage: check.name == "YouTube" ? "play.rectangle.fill" : "gamecontroller.fill").font(.system(size: 11))
                            small(check.result).monospacedDigit()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button(s.checking ? "Отменить проверку" : "Проверить подключения") { model.send("checkConnections") }.buttonStyle(.bordered).disabled(s.testing || s.zapretBusy)
            }
            VStack(alignment: .leading, spacing: 10) {
                heading("Стратегии") { EmptyView() }
                if s.testing { small(s.progress.isEmpty ? "Проверяю стратегии…" : s.progress); ProgressView().controlSize(.small) }
                Button(s.testing ? "Отменить проверку" : "Проверить все стратегии") { model.send("testStrategies") }.buttonStyle(.borderedProminent).disabled(s.checking || (s.zapretBusy && !s.testing))
                if !s.scores.isEmpty {
                    group {
                        ForEach(s.scores, id: \.name) { score in HStack { Text(score.name).font(.system(size: 11)); Spacer(minLength: 4); small(score.score).monospacedDigit(); if s.best.contains(score.name) { Image(systemName: "checkmark").font(.system(size: 10)) } }.padding(.vertical, 5) }
                        if let best = s.strategies.first(where: { s.best.contains($0.name) }), best.id != s.strategy {
                            Button("Применить: \(best.name)") { model.send("strategy", value: best.id) }.buttonStyle(.borderedProminent).controlSize(.small).disabled(s.testing || s.zapretBusy)
                        }
                    }
                }
            }
        }
    }
    private func routing(_ s: NativeMenuState) -> some View {
        Group {
            routeControls(s)
            Button { query = ""; detail = "rules" } label: { HStack { Label("Все правила", systemImage: "list.bullet"); small("\(s.runtimeRules.count)"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 10)) }.frame(maxWidth: .infinity) }.buttonStyle(.bordered)
            ruleGroup(s, site: true)
            ruleGroup(s, site: false)
        }
    }
    private func edit(_ rule: MenuRule?, site: Bool) {
        draftName = site ? rule?.name ?? "" : rule?.id ?? ""
        draftRoute = rule?.route ?? "vpn"
        previousRule = rule?.id
        detail = site ? "site" : "app"
    }
    private func ruleGroup(_ s: NativeMenuState, site: Bool) -> some View {
        VStack(spacing: 8) {
            heading(site ? "Сайты" : "Приложения") {
                HStack(spacing: 5) {
                    if site { iconButton("arrow.clockwise", "Применить правила", disabled: s.rulesBusy) { model.send("applyRules") } }
                    if site { iconButton("plus", "Добавить сайт", disabled: s.rulesBusy) { edit(nil, site: true) } }
                    else {
                        Menu {
                            Button("Выбрать приложение или процесс…") { model.send("addApps") }
                            Button("Ввести имя, путь или шаблон…") { edit(nil, site: false) }
                        } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().help("Добавить приложение").accessibilityLabel("Добавить приложение")
                    }
                }
            }
            group {
                if !site { row("Только эти приложения через VPN") { toggle("Только эти приложения через VPN", value: s.onlyListed, action: "onlyListed", disabled: s.rulesBusy) }.font(.system(size: 11)); Divider() }
                let rules = site ? s.sites : s.apps
                ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                    HStack(spacing: 5) {
                        Button { edit(rule, site: site) } label: {
                            HStack(spacing: 5) {
                                Text(rule.name).font(.system(size: 11)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                small(rule.target).font(.system(size: 10))
                            }.frame(maxWidth: .infinity, minHeight: 36).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(rule.id)
                        Button { model.send(site ? "deleteSite" : "deleteApp", value: rule.id) } label: { Image(systemName: "trash").frame(width: 24, height: 24).contentShape(Rectangle()) }.buttonStyle(.plain).foregroundStyle(.secondary).help("Удалить \(rule.name)").accessibilityLabel("Удалить \(rule.name)")
                    }.frame(minHeight: 36).disabled(s.rulesBusy)
                    if index < rules.count - 1 { Divider() }
                }
                if rules.isEmpty { small(site ? "Добавьте сайт кнопкой «+»." : "Добавьте приложение кнопкой «+».").padding(.vertical, 10) }
            }
        }
    }
    private func allRules(_ s: NativeMenuState) -> some View {
        Group {
            back("Все действующие правила")
            TextField("Домен, процесс или маршрут", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Поиск правил")
            let filtered = s.runtimeRules.filter { query.isEmpty || "\($0.name) \($0.type) \($0.target)".localizedCaseInsensitiveContains(query) }
            small("Найдено: \(filtered.count) из \(s.runtimeRules.count)")
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.offset) { _, rule in
                    HStack(alignment: .top) { VStack(alignment: .leading, spacing: 3) { Text(rule.name); small(rule.type) }; Spacer(minLength: 4); small(rule.target) }.font(.system(size: 11)).padding(.vertical, 9)
                    Divider()
                }
            }
            if filtered.isEmpty { small(s.runtimeRules.isEmpty ? "Правил нет: профиль ещё не применён." : "Правила не найдены.") }
            Button("Обновить список") { model.refresh() }.controlSize(.small)
        }
    }
    private func ruleEditor(_ s: NativeMenuState) -> some View {
        Group {
            let site = detail == "site"
            back((previousRule == nil ? "Добавить " : "Изменить ") + (site ? "сайт" : "приложение"))
            VStack(alignment: .leading, spacing: 5) {
                Text(site ? "Домен или ссылка" : "Имя, путь или шаблон").font(.system(size: 11))
                TextField(site ? "example.com" : "curl, codex*, /Applications/Example.app", text: $draftName).textFieldStyle(.roundedBorder).disabled(!site && previousRule != nil)
            }
            Picker("Маршрут", selection: $draftRoute) {
                Text("VPN").tag("vpn"); Text("Напрямую").tag("direct")
                if site { Text("Zapret → VPN").tag("zapret") }
                Text("Блок").tag("block")
            }.controlSize(.small)
            HStack {
                Button("Отмена") { detail = "" }.buttonStyle(.bordered)
                Spacer()
                Button("Сохранить") {
                    var fields: [String: Any] = ["name": draftName]
                    if let previousRule { fields["previous"] = previousRule }
                    model.send(site ? "saveSite" : "saveApp", value: draftRoute, fields: fields) { saved in if saved { detail = "" } }
                }.buttonStyle(.borderedProminent).disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || s.rulesBusy || model.busy.contains(site ? "saveSite" : "saveApp")).keyboardShortcut(.return, modifiers: [])
            }
        }
    }
    private func profiles(_ s: NativeMenuState) -> some View {
        Group {
            back("Профили")
            HStack { small("\(s.profiles.count)"); Spacer(); Button("Обновить все") { model.send("updateAll") }.controlSize(.small).disabled(s.profiles.contains { $0.updating }) }
            ForEach(s.profiles) { p in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Button { model.send("profile", value: p.id); detail = "" } label: { HStack { Text(p.name).fontWeight(.semibold); if p.id == s.currentProfileId { Image(systemName: "checkmark").foregroundStyle(accent) } }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
                        iconButton("arrow.clockwise", "Обновить \(p.name)", disabled: p.updating) { model.send("updateProfile", value: p.id) }
                    }
                    profileUsage(p)
                }.padding(11).background(p.id == s.currentProfileId ? accent.opacity(0.1) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(p.id == s.currentProfileId ? accent : Color(nsColor: .separatorColor), lineWidth: 1) }
            }
            HStack {
                Button { model.send("addProfile") } label: { Label("Добавить", systemImage: "plus") }
                Spacer(); Button("Управление") { model.send("manageProfiles") }
            }.buttonStyle(.bordered).controlSize(.small)
        }
    }
    private func settings(_ s: NativeMenuState) -> some View {
        Group {
            VStack(alignment: .leading, spacing: 12) {
                heading("Акцентный цвет") { EmptyView() }
                HStack(spacing: 0) {
                    ForEach(Array(MenuPalette.accents.enumerated()), id: \.offset) { _, choice in
                        Button { model.send("accent", value: choice.1) } label: {
                            VStack(spacing: 6) {
                                ZStack { Circle().fill(MenuPalette.color(choice.1)).frame(width: 25, height: 25); if s.accent == choice.1 { Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(nsColor: .controlBackgroundColor)) } }
                                Text(choice.0).font(.system(size: 9)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(choice.0).accessibilityAddTraits(s.accent == choice.1 ? .isSelected : [])
                    }
                }
            }
            group {
                row("Оформление") { Picker("Оформление", selection: Binding(get: { s.appearance }, set: { model.send("appearance", value: $0) })) { Text("Системное").tag("system"); Text("Светлое").tag("light"); Text("Тёмное").tag("dark") }.labelsHidden().controlSize(.small).frame(maxWidth: 150) }
                Divider(); row("Запускать при входе") { toggle("Запускать при входе", value: s.autoLaunch, action: "autoLaunch") }
                Divider(); row("Открывать") { Picker("Открывать", selection: Binding(get: { s.startPage }, set: { model.send("startPage", value: $0) })) { ForEach(pages, id: \.0) { p in Text(p.1).tag(p.0) } }.labelsHidden().controlSize(.small).frame(maxWidth: 150) }
            }
            VStack(alignment: .leading, spacing: 8) {
                heading("Сеть") { EmptyView() }
                group {
                    row("System Proxy") { toggle("System Proxy", value: s.systemProxy, action: "systemProxy") }; Divider()
                    row("TUN") { toggle("TUN", value: s.tun, action: "tun") }
                }
            }
            Button { model.send("allSettings") } label: { HStack { Text("Все настройки"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 10)) }.frame(maxWidth: .infinity) }.buttonStyle(.bordered)
            if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { small("CustomVPN \(version)").font(.system(size: 10)) }
        }
    }
}

private struct MenuModeSelector: NSViewRepresentable {
    let mode: String
    let enabled: Bool
    let change: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(change: change) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["By rule", "Global", "Direct"], trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.choose(_:)))
        control.controlSize = .small; control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel("Режим маршрутизации")
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        control.selectedSegment = ["rule", "global", "direct"].firstIndex(of: mode) ?? -1
        control.isEnabled = enabled; context.coordinator.change = change
    }
    final class Coordinator: NSObject {
        var change: (String) -> Void
        init(change: @escaping (String) -> Void) { self.change = change }
        @objc func choose(_ sender: NSSegmentedControl) { change(["rule", "global", "direct"][sender.selectedSegment]) }
    }
}

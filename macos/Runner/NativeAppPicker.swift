import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NativeAppPicker: View {
    @ObservedObject var model: NativeMenuModel
    let cancel, manual: () -> Void
    @State var kind = "apps"
    @State private var items = [MenuAppEntry]()
    @State private var selected = Set<String>()
    @State private var query = ""
    @State private var loading = false
    @State private var loadEpoch = 0
    @State private var patternEpoch = 0
    @State private var onePattern = false
    @State private var byPath = false
    @State private var matchModeEdited = false
    @State private var pattern = ""
    @State private var patternEdited = false
    @State private var preview: MenuProcessPattern?
    @State private var pendingFiles = [String]()
    @State private var chosenFiles = [String: MenuAppEntry]()

    private var filtered: [MenuAppEntry] {
        items.filter { query.isEmpty || "\($0.name) \($0.path)".localizedCaseInsensitiveContains(query) }
    }
    private var values: [String] {
        if kind == "apps" { return selected.sorted() }
        if onePattern { return [pattern.trimmingCharacters(in: .whitespacesAndNewlines)] }
        return Array(Set(items.filter { selected.contains($0.path) }.map { byPath ? $0.path : $0.name })).sorted()
    }
    private var ready: Bool { !selected.isEmpty && !loading && (!onePattern || (preview != nil && preview?.error == nil)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: cancel) { Label("Назад", systemImage: "chevron.left") }.buttonStyle(.plain)
                Spacer()
                Button(action: load) { Image(systemName: "arrow.clockwise") }.buttonStyle(.bordered).controlSize(.small).disabled(loading).help("Обновить список")
            }.font(.system(size: 12))
            Text("Добавить приложение").font(.system(size: 14, weight: .semibold))
            Picker("Источник", selection: $kind) {
                Text("Приложения").tag("apps"); Text("Процессы").tag("processes")
            }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .onChange(of: kind) { _ in selected.removeAll(); query = ""; preview = nil; onePattern = false; patternEdited = false; load() }
            TextField("Поиск по имени или пути", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Поиск приложений и процессов")
            if loading {
                Spacer(); HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }; Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 3) {
                        ForEach(filtered) { item in
                            Button { select(item) } label: {
                                HStack(spacing: 8) {
                                    if kind == "apps" {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 22, height: 22)
                                    } else {
                                        Image(systemName: item.network ? "network" : "terminal").frame(width: 22).foregroundStyle(.secondary)
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name).font(.system(size: 12)).lineLimit(1)
                                        Text(item.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: selected.contains(item.path) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(item.path) ? MenuPalette.color(model.state?.accent) : .secondary)
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    .background(selected.contains(item.path) ? MenuPalette.color(model.state?.accent).opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).help(item.path).accessibilityLabel(item.name).accessibilityAddTraits(selected.contains(item.path) ? .isSelected : [])
                        }
                        if filtered.isEmpty { Text("Ничего не найдено").font(.system(size: 12)).foregroundStyle(.secondary).padding(20) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if kind == "processes" && !selected.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Picker("Правила", selection: $onePattern) { Text("По отдельности").tag(false); Text("Один шаблон").tag(true) }.labelsHidden()
                        Picker("Совпадение", selection: Binding(get: { byPath }, set: { byPath = $0; matchModeEdited = true; patternEdited = false; updatePattern() })) { Text("По имени").tag(false); Text("По пути").tag(true) }.labelsHidden()
                    }.controlSize(.small).onChange(of: onePattern) { _ in updatePattern() }
                    if onePattern {
                        TextField("Шаблон процесса", text: Binding(get: { pattern }, set: { pattern = $0; patternEdited = true; updatePattern() })).textFieldStyle(.roundedBorder)
                        if let preview {
                            Text(preview.error ?? "Совпадает: \(preview.matches.count)").font(.system(size: 10)).foregroundStyle(preview.error == nil ? .secondary : Color.red)
                            if !preview.extra.isEmpty { Text("Также поймает: \(preview.extra.joined(separator: ", "))").font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2) }
                        }
                    }
                }
            }
            HStack {
                Menu("Вручную") {
                    Button("Выбрать .app в Finder…", action: chooseFile)
                    Button("Имя, путь или шаблон…", action: manual)
                }.fixedSize().menuStyle(.borderlessButton)
                Spacer()
                Button("Добавить\(values.isEmpty ? "" : " (\(values.count))")") {
                    model.send("saveApps", value: values) { saved in if saved { cancel() } }
                }.buttonStyle(.borderedProminent).disabled(!ready || model.busy.contains("saveApps"))
            }.controlSize(.small)
        }.onAppear(perform: load).onDisappear { loadEpoch += 1; patternEpoch += 1 }
    }
    private func select(_ item: MenuAppEntry) {
        if selected.contains(item.path) { selected.remove(item.path) } else { selected.insert(item.path) }
        if kind == "processes" {
            if selected.isEmpty { matchModeEdited = false; byPath = false }
            else if !matchModeEdited { byPath = items.filter { selected.contains($0.path) }.contains { $0.name.rangeOfCharacter(from: .letters) == nil } }
            updatePattern()
        }
    }
    private func load() {
        loadEpoch += 1
        let epoch = loadEpoch
        loading = true
        model.request("appCatalog", args: ["kind": kind], as: MenuAppCatalog.self) { result in
            guard epoch == loadEpoch else { return }
            loading = false
            switch result {
            case .success(let catalog):
                items = catalog.items
                if kind == "apps" {
                    let paths = Set(items.map(\.path))
                    items.append(contentsOf: chosenFiles.values.filter { !paths.contains($0.path) })
                }
                selected.formIntersection(items.map(\.path))
                if kind == "processes" { updatePattern() }
            case .failure(let error): items = []; model.message = error.localizedDescription
            }
            if !pendingFiles.isEmpty { mergeFiles(pendingFiles); pendingFiles = [] }
        }
    }
    private func updatePattern() {
        patternEpoch += 1
        let epoch = patternEpoch
        preview = nil
        guard !selected.isEmpty else { pattern = ""; patternEdited = false; return }
        var args: [String: Any] = ["paths": selected.sorted(), "byPath": byPath]
        if patternEdited { args["pattern"] = pattern }
        model.request("processPattern", args: args, as: MenuProcessPattern.self) { result in
            guard epoch == patternEpoch else { return }
            switch result {
            case .success(let value): preview = value; if !patternEdited { pattern = value.pattern }
            case .failure(let error): model.message = error.localizedDescription
            }
        }
    }
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { response in
            guard response == .OK else { return }
            let paths = panel.urls.map(\.path)
            if kind == "apps" { mergeFiles(paths) }
            else { pendingFiles = paths; kind = "apps" }
        }
    }
    private func mergeFiles(_ paths: [String]) {
        query = ""
        for path in paths {
            let entry = MenuAppEntry(name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, path: path, network: false)
            chosenFiles[path] = entry
            if !items.contains(where: { $0.path == path }) {
                items.append(entry)
            }
            selected.insert(path)
        }
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ManagerTab: String, CaseIterable, Identifiable {
    case devices = "Übersicht"
    case storage = "Speicher"
    case system = "System"
    case roms = "ROMs"
    case files = "Dateien"
    case apps = "Apps & Launcher"
    case profiles = "Emulator-Einstellungen"
    var id: String { rawValue }
    var title: String { NSLocalizedString(rawValue, comment: "Navigation section") }
    var symbol: String {
        switch self {
        case .devices: return "gamecontroller"; case .files: return "folder"; case .profiles: return "slider.horizontal.3"
        case .apps: return "square.stack.3d.up"; case .system: return "gearshape.2"; case .storage: return "chart.pie"
        case .roms: return "opticaldiscdrive"
        }
    }
}

private let sidebarSections: [(title: String, tabs: [ManagerTab])] = [
    ("Gerät", [.devices, .storage, .system]),
    ("Bibliothek", [.roms, .files]),
    ("Apps", [.apps, .profiles]),
]

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab: ManagerTab? = .devices

    var body: some View {
        NavigationSplitView {
            List(selection: $tab) {
                ForEach(sidebarSections, id: \.title) { section in
                    Section(NSLocalizedString(section.title, comment: "Sidebar group")) {
                        ForEach(section.tabs) { item in
                            Label(item.title, systemImage: item.symbol).tag(item)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Handheld Manager")
            .navigationSplitViewColumnWidth(min: 185, ideal: 215, max: 260)
        } detail: {
            selectedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(tab?.title ?? "Handheld Manager")
                .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
                .toolbar { toolbarItems }
        }
        .navigationSplitViewStyle(.balanced)
        .task { await model.refresh() }
        .onChange(of: model.selectedSerial) { _, value in Task { await model.chooseDevice(value) } }
        .alert(model.finalConfirmation?.title ?? "", isPresented: Binding(
            get: { model.finalConfirmation != nil },
            set: { if !$0 { model.finalConfirmation = nil } }
        )) {
            Button(model.finalConfirmation?.confirmLabel ?? "OK", role: .destructive) {
                let action = model.finalConfirmation?.action
                model.finalConfirmation = nil
                action?()
            }
            Button("Abbrechen", role: .cancel) { model.finalConfirmation = nil }
        } message: { Text(model.finalConfirmation?.message ?? "") }
        .alert("Aktion fehlgeschlagen", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(NSLocalizedString(model.errorMessage ?? "", comment: "Error message")) }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch tab ?? .devices {
        case .devices: DeviceOverviewView { tab = $0 }
        case .files: DeviceFilesView()
        case .profiles: EmulatorProfilesView()
        case .apps: AppsLauncherView()
        case .system: SystemFirmwareView()
        case .storage: StorageAnalysisView()
        case .roms: RomLibraryView()
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Gerät", selection: Binding(
                get: { model.selectedSerial ?? "" },
                set: { value in Task { await model.chooseDevice(value.isEmpty ? nil : value) } }
            )) {
                Text("Kein Gerät").tag("")
                ForEach(model.connections) { device in
                    Text("\(device.displayName) · \(device.state)").tag(device.serial)
                }
            }
            .frame(maxWidth: 260)
            .disabled(model.connections.isEmpty || model.isBusy)
            Button { Task { await model.refresh() } } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                .help("Geräte und Fähigkeiten neu erkennen").disabled(model.isBusy)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isBusy { ProgressView().controlSize(.small) }
            Text(NSLocalizedString(model.busyLabel ?? model.statusMessage, comment: "App status")).lineLimit(1)
                .foregroundStyle(model.errorMessage == nil ? Color.secondary : Color.red)
            Spacer(minLength: 12)
            if let serial = model.selectedSerial {
                Text("ADB · …\(serial.suffix(4))").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct DeviceOverviewView: View {
    @EnvironmentObject private var model: AppModel
    let open: (ManagerTab) -> Void

    var body: some View {
        if let device = model.descriptor {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header(device)
                    actions(device)
                    emulators(device)
                    technicalDetails(device)
                }.padding(24).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
            }
        } else {
            SetupGuideView(connection: model.selectedConnection)
        }
    }

    private func header(_ device: DeviceDescriptor) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 34)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.title).font(.title.bold())
                Text("Android \(device.androidVersion)" + (device.build.isEmpty ? "" : " · Build \(device.build)"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label("Verbunden", systemImage: "circle.fill").foregroundStyle(.green)
                .labelStyle(.titleAndIcon).font(.callout)
        }
    }

    private func actions(_ device: DeviceDescriptor) -> some View {
        let updates = device.packages.filter { $0.updateAvailable == true }.count
        return VStack(alignment: .leading, spacing: 10) {
            Text("Was möchtest du tun?").font(.headline)
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    actionCard("Spiele hinzufügen", "ROMs ansehen und Dateien auf das Gerät übertragen", "opticaldiscdrive", .roms)
                    actionCard("Apps installieren", updates > 0 ? "\(updates) Update(s) verfügbar" : "APK installieren oder Emulatoren aktualisieren", "square.and.arrow.down", .apps, badge: updates)
                }
                GridRow {
                    actionCard("Einstellungen sichern", "Emulator-Konfigurationen sichern und zurückspielen", "slider.horizontal.3", .profiles)
                    actionCard("Speicher aufräumen", device.volumes.compactMap(\.capacity).first.map { "Kapazität \($0)" } ?? "Größte Dateien und Ordner finden", "chart.pie", .storage)
                }
            }
        }
    }

    private func actionCard(_ title: LocalizedStringKey, _ detail: String, _ symbol: String, _ tab: ManagerTab, badge: Int = 0) -> some View {
        Button { open(tab) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title2).frame(width: 34).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(badge > 0 ? Color.orange : Color.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder
    private func emulators(_ device: DeviceDescriptor) -> some View {
        let list = EmulatorCatalog.knownEmulators(in: device.packages)
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Installierte Emulatoren").font(.headline)
                VStack(spacing: 0) {
                    ForEach(list) { package in
                        HStack {
                            Text(package.displayTitle)
                            Spacer()
                            Text(package.versionName ?? "").foregroundStyle(.secondary)
                            if package.updateAvailable == true { Image(systemName: "arrow.up.circle.fill").foregroundStyle(.orange).help("Update verfügbar") }
                        }.padding(.vertical, 8).padding(.horizontal, 12)
                        if package.id != list.last?.id { Divider() }
                    }
                }.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func technicalDetails(_ device: DeviceDescriptor) -> some View {
        DisclosureGroup("Technische Details") {
            VStack(alignment: .leading, spacing: 16) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow { Text("Hersteller").foregroundStyle(.secondary); Text("\(device.manufacturer) · \(device.device)") }
                    GridRow { Text("API-Level").foregroundStyle(.secondary); Text("\(device.apiLevel)") }
                    GridRow { Text("Sicherheitsupdate").foregroundStyle(.secondary); Text(device.securityPatch.isEmpty ? "Unbekannt" : device.securityPatch) }
                    GridRow { Text("Fingerprint").foregroundStyle(.secondary); Text(device.fingerprint.isEmpty ? "Unbekannt" : device.fingerprint).textSelection(.enabled).font(.caption.monospaced()) }
                }
                ForEach(device.volumes) { volume in
                    HStack {
                        Image(systemName: volume.kind == .internalStorage ? "internaldrive" : "sdcard")
                        VStack(alignment: .leading) {
                            Text(volume.name).fontWeight(.medium)
                            Text(volume.path).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let capacity = volume.capacity { Text(capacity).font(.caption).foregroundStyle(.secondary) }
                        Image(systemName: volume.readable ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(volume.readable ? .green : .secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(device.reports) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: symbol(for: item.state)).foregroundStyle(color(for: item.state)).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { Text(item.title).fontWeight(.medium); Spacer(); Text(item.state.rawValue).font(.caption).foregroundStyle(color(for: item.state)) }
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.padding(.top, 10)
        }
    }

    private func symbol(for state: CapabilityState) -> String {
        switch state { case .supported: return "checkmark.circle.fill"; case .unavailable: return "xmark.circle.fill"; case .requiresOnDeviceAction: return "hand.tap.fill"; case .unknown: return "questionmark.circle" }
    }
    private func color(for state: CapabilityState) -> Color {
        switch state { case .supported: return .green; case .unavailable: return .secondary; case .requiresOnDeviceAction: return .orange; case .unknown: return .secondary }
    }
}

private struct SetupGuideView: View {
    @EnvironmentObject private var model: AppModel
    let connection: DeviceConnection?

    private var waitingForApproval: Bool { connection != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: waitingForApproval ? "lock.shield" : "cable.connector.slash")
                    .font(.system(size: 44, weight: .light)).foregroundStyle(.secondary)
                Text(waitingForApproval ? "Freigabe am Handheld fehlt" : "Kein Handheld verbunden").font(.title2.weight(.semibold))
                Text(waitingForApproval
                     ? "Das Gerät ist verbunden, aber noch nicht für diesen Mac freigegeben (Status: \(connection?.state ?? "")). Entsperre das Handheld und bestätige die Abfrage."
                     : "So richtest du dein Android-Handheld ein. Das ist einmalig.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Entwickleroptionen freischalten", "Öffne Einstellungen → System → Über das Gerät (je nach Gerät auch „Über das Telefon“). Tippe siebenmal schnell auf die Build-Nummer. Android meldet „Du bist jetzt Entwickler“.", done: false)
                    step(2, "USB-Debugging einschalten", "Öffne Einstellungen → System → Entwickleroptionen und aktiviere „USB-Debugging“. Bestätige die Sicherheitsabfrage mit OK.", done: false)
                    step(3, "Per USB verbinden", "Nimm ein Datenkabel (kein reines Ladekabel) und stecke es direkt an den Mac. Falls Android nach dem USB-Modus fragt, wähle „Dateiübertragung“.", done: connection != nil)
                    step(4, "Am Handheld freigeben", "Beim ersten Verbinden erscheint „USB-Debugging zulassen?“ mit dem Fingerabdruck deines Macs. Hake „Immer von diesem Computer zulassen“ an und tippe auf „Zulassen“. Das Gerät muss dabei entsperrt sein.", done: false, highlight: waitingForApproval)
                }
                .frame(maxWidth: 560, alignment: .leading)
                Button("Erneut suchen", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .buttonStyle(.borderedProminent).disabled(model.isBusy)
            }
            .padding(32).frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ number: Int, _ title: LocalizedStringKey, _ text: LocalizedStringKey, done: Bool, highlight: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle.fill")
                .font(.title2).foregroundStyle(done ? Color.green : (highlight ? Color.orange : Color.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(highlight ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct DeviceFilesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedPaths = Set<String>()
    @State private var showUploadPicker = false
    @State private var pendingUpload: URL?
    @State private var confirmUpload = false
    @State private var confirmQuarantine = false
    @State private var confirmPermanentDelete = false
    @State private var pendingDeleteEntries: [DeviceFileEntry] = []
    @State private var renameEntry: DeviceFileEntry?
    @State private var confirmFileRollback = false

    private var selectedEntries: [DeviceFileEntry] { model.files.filter { selectedPaths.contains($0.path) } }
    private var selectedEntry: DeviceFileEntry? { selectedEntries.count == 1 ? selectedEntries.first : nil }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let volume = model.selectedVolume {
                List(selection: Binding(
                    get: { selectedPaths },
                    set: { paths in
                        selectedPaths = paths
                        model.selectedFilePath = paths.count == 1 ? paths.first : nil
                    }
                )) {
                    ForEach(model.files) { entry in
                        HStack(spacing: 9) {
                            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name).lineLimit(1)
                                if !entry.isDirectory {
                                    Text("Dateigröße: \(entry.size.humanBytes)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .accessibilityLabel("Dateigröße \(entry.size.humanBytes)")
                                }
                            }
                            Spacer()
                            Text(entry.modified).foregroundStyle(.tertiary).font(.caption)
                        }
                        .contentShape(Rectangle())
                        .tag(entry.path)
                    }
                }
                .contextMenu(forSelectionType: String.self) { paths in
                    let entries = model.files.filter { paths.contains($0.path) }
                    if entries.count == 1, let entry = entries.first {
                        if entry.isDirectory {
                            Button("Öffnen", systemImage: "folder") { Task { await model.open(entry) } }
                        } else {
                            Button("Herunterladen…", systemImage: "arrow.down.to.line") { saveSelectedFile(entry) }
                        }
                        Button("Umbenennen…", systemImage: "pencil") { renameEntry = entry }
                        Button("Gerätepfad kopieren", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.path, forType: .string)
                        }
                        Divider()
                        Button("In Quarantäne verschieben…", systemImage: "trash") {
                            model.selectedFilePath = entry.path
                            selectedPaths = [entry.path]
                            confirmQuarantine = true
                        }
                    }
                    if !entries.isEmpty {
                        Button("Endgültig löschen…", systemImage: "trash", role: .destructive) {
                            requestDelete(entries)
                        }
                    }
                } primaryAction: { paths in
                    guard paths.count == 1, let entry = model.files.first(where: { paths.contains($0.path) }) else { return }
                    activate(entry)
                }
                .onDeleteCommand { requestDelete(selectedEntries) }
                .onChange(of: model.currentPath) { _, _ in selectedPaths.removeAll() }
                .onChange(of: model.files) { _, files in
                    let validPaths = Set(files.map(\.path))
                    if let path = model.selectedFilePath, validPaths.contains(path) {
                        selectedPaths = [path]
                    } else {
                        selectedPaths.formIntersection(validPaths)
                    }
                    model.selectedFilePath = selectedPaths.count == 1 ? selectedPaths.first : nil
                }
                .overlay {
                    if model.files.isEmpty && !model.isBusy {
                        ContentUnavailableView("Ordner ist leer", systemImage: "folder", description: Text("Du kannst eine Datei vom Mac in diesen Ordner übertragen."))
                    }
                }
                HStack {
                    Text("\(model.files.count) Einträge · \(selectedPaths.count) ausgewählt · \(volume.name)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if model.fileBackupAvailable { Button("Vorherige Version zurückspielen") { confirmFileRollback = true } }
                    if model.lastQuarantine?.deviceSerial == model.selectedSerial { Button("Letzte Löschung rückgängig") { Task { await model.undoQuarantine() } } }
                    Button("Umbenennen…") { if let selectedEntry { renameEntry = selectedEntry } }
                        .disabled(selectedEntry == nil || model.isBusy)
                    Button("In Quarantäne verschieben…") { confirmQuarantine = true }
                        .disabled(selectedEntry == nil || model.isBusy)
                    Button {
                        requestDelete(selectedEntries)
                    } label: { Image(systemName: "trash") }
                        .help("Ausgewählte Einträge endgültig löschen")
                        .accessibilityLabel("Ausgewählte Einträge endgültig löschen")
                        .tint(.red)
                        .disabled(selectedEntries.isEmpty || model.isBusy)
                    Button("Herunterladen…") { saveSelectedFile() }
                        .disabled(selectedEntry == nil || selectedEntry?.isDirectory == true || model.isBusy)
                    Button("Datei hochladen…") { showUploadPicker = true }.disabled(model.isBusy || !volume.writable)
                }.padding(12)
            } else {
                ContentUnavailableView("Kein Speicherort", systemImage: "externaldrive", description: Text("Wähle ein verbundenes Gerät mit erreichbarem Speicher.")).frame(maxHeight: .infinity)
            }
        }
        .fileImporter(isPresented: $showUploadPicker, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                pendingUpload = url
                Task {
                    await model.prepareUpload(url)
                    confirmUpload = model.uploadPreview != nil
                }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .alert("Datei zum Gerät übertragen?", isPresented: $confirmUpload) {
            Button("Übertragen mit Backup") {
                guard let pendingUpload else { return }
                Task { await model.upload(pendingUpload, replaceExisting: true) }
            }
            Button("Abbrechen", role: .cancel) { pendingUpload = nil }
        } message: {
            Text(uploadConfirmationText)
        }
        .alert("Datei oder Ordner in Quarantäne verschieben?", isPresented: $confirmQuarantine) {
            Button("Verschieben", role: .destructive) { model.confirmAgain("Wirklich in Quarantäne verschieben?", "Die Dateien werden in den Papierkorb (Quarantäne) auf dem Handheld verschoben und lassen sich zurückholen.", label: "Ja, verschieben") { Task { await model.quarantineSelected() } } }
            Button("Abbrechen", role: .cancel) { }
        } message: { Text(quarantineConfirmationText) }
        .confirmationDialog("Einträge endgültig löschen?", isPresented: $confirmPermanentDelete, titleVisibility: .visible) {
            Button("Endgültig löschen", role: .destructive) {
                let entries = pendingDeleteEntries
                model.confirmAgain("Wirklich endgültig löschen?", "\(entries.count) Eintrag/Einträge werden dauerhaft gelöscht. Zur Sicherheit noch einmal: Das Löschen kann nicht rückgängig gemacht werden.") {
                    Task {
                        await model.deleteSelectedPermanently(entries)
                        selectedPaths.subtract(entries.map(\.path))
                        pendingDeleteEntries = []
                    }
                }
            }
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text(pendingDeleteEntries.map { "\($0.name) · \($0.size.humanBytes)" }.joined(separator: "\n") + "\nDer Eintrag samt Inhalt wird dauerhaft gelöscht und kann nicht wiederhergestellt werden.")
        }
        .alert("Vorherige Dateiversion wiederherstellen?", isPresented: $confirmFileRollback) {
            Button("Wiederherstellen", role: .destructive) { Task { await model.rollbackFileReplacement() } }
            Button("Abbrechen", role: .cancel) { }
        } message: { Text("Die aktuell ausgewählte Zielversion wird durch das letzte lokale, hashgeprüfte Backup ersetzt.") }
        .sheet(item: $renameEntry) { entry in
            RenameDeviceFileSheet(entry: entry)
                .environmentObject(model)
        }
    }

    private func requestDelete(_ entries: [DeviceFileEntry]) {
        guard !entries.isEmpty else { return }
        pendingDeleteEntries = entries
        confirmPermanentDelete = true
    }

    private func activate(_ entry: DeviceFileEntry) {
        model.selectedFilePath = entry.path
        selectedPaths = [entry.path]
        if entry.isDirectory {
            Task { await model.open(entry) }
        } else {
            saveSelectedFile(entry)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Volume", selection: Binding(
                get: { model.selectedVolumeID ?? "" },
                set: { value in Task { await model.chooseVolume(value.isEmpty ? nil : value) } }
            )) {
                ForEach(model.descriptor?.volumes ?? []) { volume in Text(volume.name).tag(volume.id) }
            }.frame(width: 170).disabled(model.isBusy || model.descriptor?.volumes.isEmpty != false)
            Button { Task { await model.goToParent() } } label: { Image(systemName: "arrow.up") }.help("Übergeordneten Ordner öffnen")
            TextField("Gerätepfad", text: $model.currentPath)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.loadFiles() } }
            Button("Öffnen") { Task { await model.loadFiles() } }.disabled(model.isBusy || model.selectedVolume == nil)
            Button { Task { await model.loadFiles() } } label: { Image(systemName: "arrow.clockwise") }.disabled(model.isBusy || model.selectedVolume == nil)
        }.padding(12)
    }

    private var uploadConfirmationText: String {
        guard let preview = model.uploadPreview else { return "Keine Uploadvorschau verfügbar." }
        let collision = preview.destinationExists ? "Das vorhandene Ziel wird vorher lokal gesichert und ersetzt." : "Am Ziel ist aktuell keine Datei vorhanden."
        return ["Quelle: \(preview.source)", "Ziel: \(preview.destination)", "Größe: \(preview.size.humanBytes)", "SHA-256: \(preview.sha256)", collision].joined(separator: "\n")
    }

    private var quarantineConfirmationText: String {
        guard let entry = selectedEntry else { return "" }
        return "\(entry.path) · \(entry.size.humanBytes). Datei oder Ordner wird im gleichen Volume in .HandheldManagerTrash verschoben und kann über ‚Letzte Löschung rückgängig‘ zurückgeholt werden."
    }

    private func saveSelectedFile(_ requestedEntry: DeviceFileEntry? = nil) {
        guard let entry = requestedEntry ?? selectedEntry else { return }
        model.selectedFilePath = entry.path
        selectedPaths = [entry.path]
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { Task { await model.downloadSelected(to: url) } }
    }
}

private struct RenameDeviceFileSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFieldFocused: Bool
    let entry: DeviceFileEntry
    @State private var name: String

    init(entry: DeviceFileEntry) {
        self.entry = entry
        _name = State(initialValue: entry.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Umbenennen").font(.title2.weight(.semibold))
            Text(entry.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit(rename)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Umbenennen", action: rename).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
            }
        }
        .padding(22)
        .frame(width: 480)
        .task { nameFieldFocused = true }
    }

    private func rename() {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            await model.renameFile(entry, to: name)
            if model.errorMessage == nil { dismiss() }
        }
    }
}

private struct StorageAnalysisView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingDeletion: StorageUsageEntry?
    @State private var showRemovalOptions = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Volume", selection: Binding(
                    get: { model.storageScanVolumeID ?? model.selectedVolumeID ?? "" },
                    set: { value in Task { await model.chooseVolume(value.isEmpty ? nil : value) } }
                )) {
                    ForEach(model.descriptor?.volumes ?? []) { volume in Text(volume.name).tag(volume.id) }
                }
                .frame(width: 190)
                if let volume = model.descriptor?.volumes.first(where: { $0.id == model.storageScanVolumeID }) ?? model.selectedVolume {
                    Text(volume.capacity ?? "Speicherstand nicht ermittelt").foregroundStyle(volume.capacity == nil ? .orange : .secondary)
                }
                if let volume = model.descriptor?.volumes.first(where: { $0.id == model.storageScanVolumeID }) ?? model.selectedVolume,
                   let scanPath = model.storageScanPath, scanPath != volume.path {
                    Button("Eine Ebene höher", systemImage: "arrow.up") { Task { await model.goToStorageParent() } }
                        .disabled(model.isBusy || scanPath == volume.path)
                }
                Spacer()
                if model.lastQuarantine?.deviceSerial == model.selectedSerial {
                    Button("Letzte Verschiebung rückgängig") { Task { await model.undoQuarantine() } }
                }
                Button("Speicher analysieren") { Task { await model.scanStorageUsage() } }
                    .disabled(model.isBusy || model.selectedVolume == nil || !model.canWorkWithDevice)
            }
            .padding(12)
            Divider()
            if let scanPath = model.storageScanPath {
                HStack {
                    Text("Analysierter Ordner:").foregroundStyle(.secondary)
                    Text(scanPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                    Spacer()
                }.padding(.horizontal, 12).padding(.top, 8)
            }
            if model.storageScanPath != nil {
                HStack {
                    InfoHint("Dateien und Ordner nach Größe sortiert · Ordnergrößen werden im Hintergrund berechnet.")
                    Spacer(minLength: 0)
                }.padding(.horizontal, 12).padding(.top, 8)
            }
            if model.storageUsageEntries.isEmpty {
                if let scanPath = model.storageScanPath {
                    ContentUnavailableView("Keine erreichbaren Dateien in diesem Ordner", systemImage: "folder", description: Text("\(scanPath) ist geöffnet. Der Ordner ist leer oder Android blendet seinen Inhalt für ADB aus.")).frame(maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Noch keine Speicheranalyse", systemImage: "chart.bar.xaxis", description: Text("Wähle ein Volume und starte die Analyse. Sie zeigt Datei- und Ordnergrößen aus dem über ADB erreichbaren gemeinsamen Speicher.")).frame(maxHeight: .infinity)
                }
            } else {
                List(model.storageUsageEntries.sorted {
                    if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }) { entry in
                    HStack(spacing: 10) {
                        if entry.isDirectory {
                            Button {
                                Task { await model.scanStorageFolder(entry.path, volumeID: entry.volumeID) }
                            } label: {
                                storageRowContent(entry) {
                                    Label("Ordner öffnen", systemImage: "chevron.right")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(model.isBusy)
                            .help("Ordner öffnen und Inhalte ansehen")
                        } else {
                            storageRowContent(entry) { EmptyView() }
                        }
                        Button {
                            pendingDeletion = entry
                            showRemovalOptions = true
                        } label: {
                            Image(systemName: "trash.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help(entry.isDirectory ? "Ordner samt Inhalt entfernen" : "Datei entfernen")
                        .accessibilityLabel(entry.isDirectory ? "Ordner löschen: \((entry.path as NSString).lastPathComponent)" : "Datei löschen: \((entry.path as NSString).lastPathComponent)")
                        .disabled(model.isBusy)
                    }
                }
                .listStyle(.inset)
                HStack {
                    Text("\(model.storageUsageEntries.count) Einträge · Ordner zum Durchsuchen, Dateien einzeln entfernbar · Android kann private Appdaten ausblenden").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(12)
            }
        }
        .confirmationDialog(pendingDeletion?.isDirectory == true ? "Ordner entfernen?" : "Datei entfernen?", isPresented: $showRemovalOptions, titleVisibility: .visible) {
            Button(pendingDeletion?.isDirectory == true ? "Ordner in Quarantäne verschieben" : "In Quarantäne verschieben") {
                if let entry = pendingDeletion { model.confirmAgain("Wirklich in Quarantäne verschieben?", "\((entry.path as NSString).lastPathComponent): Die Dateien werden in den Papierkorb (Quarantäne) auf dem Handheld verschoben und lassen sich zurückholen.", label: "Ja, verschieben") { Task { await model.quarantineStorageFile(entry) } } }
            }
            Button(pendingDeletion?.isDirectory == true ? "Ordner samt Inhalt endgültig löschen" : "Endgültig löschen", role: .destructive) {
                if let entry = pendingDeletion { model.confirmAgain("Wirklich endgültig löschen?", "\((entry.path as NSString).lastPathComponent) wird dauerhaft gelöscht. Zur Sicherheit noch einmal: Das Löschen kann nicht rückgängig gemacht werden.") { Task { await model.deleteStorageFilePermanently(entry) } } }
            }
            Button("Abbrechen", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text(pendingDeletion.map { entry in
                let size = entry.isDirectory
                    ? (model.storageUnmeasuredPaths.contains(entry.path) ? "Ordnergröße nicht ermittelt" : entry.sizeBytes.humanBytes)
                    : entry.sizeBytes.humanBytes
                return "\(entry.path) · \(size). Quarantäne ist rückgängig zu machen; endgültiges Löschen kann nicht wiederhergestellt werden."
            } ?? "")
        }
    }

    private func storageRowContent<Trailing: View>(
        _ entry: StorageUsageEntry,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text((entry.path as NSString).lastPathComponent).fontWeight(.medium).lineLimit(1)
                Text(entry.isDirectory
                     ? (model.storageSizingPaths.contains(entry.path)
                        ? "Ordnergröße wird berechnet …"
                        : (model.storageUnmeasuredPaths.contains(entry.path) ? "Ordnergröße nicht ermittelt" : "Ordnergröße: \(entry.sizeBytes.humanBytes)"))
                     : "Dateigröße: \(entry.sizeBytes.humanBytes)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(entry.isDirectory && model.storageSizingPaths.contains(entry.path) ? Color.accentColor : Color.secondary)
                Text(entry.path).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).textSelection(.enabled)
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct SystemFirmwareView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showFirmwarePicker = false
    @State private var showOverclockImagePicker = false
    @State private var confirmOverclockAction = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("Live-Systemstatus") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let gpu = model.overclockRuntimeStatus, gpu.deviceSerial == model.selectedSerial {
                            Label(gpu.isOverclocked ? "Overclock erkannt" : "Overclock nicht erkannt", systemImage: gpu.isOverclocked ? "bolt.fill" : "bolt.slash.fill")
                                .font(.headline).foregroundStyle(gpu.isOverclocked ? .orange : .secondary)
                            HStack {
                                LabeledContent("GPU-Maximum", value: "\(gpu.maximumMHz) MHz")
                                if let current = gpu.currentMHz { LabeledContent("Aktuell", value: "\(current) MHz") }
                            }
                            InfoHint("Live aus der GPU-Frequenzgrenze des Flip 2 gelesen; bei diesem 905OC-Image ist 905 MHz das Erkennungsmerkmal.")
                        } else {
                            Label("GPU-Status nicht lesbar", systemImage: "questionmark.circle")
                                .foregroundStyle(.orange)
                            Text("Verbinde das Gerät und aktualisiere den Status.").font(.caption).foregroundStyle(.secondary)
                        }
                        if let image = model.loadedBootImage, image.deviceSerial == model.selectedSerial {
                            Text("Von der App gestartet: \(image.fileName) · SHA-256 \(image.sha256.prefix(12))…")
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                if let image = model.loadedBootImage, image.deviceSerial == model.selectedSerial {
                    GroupBox("Boot-Image dieser Sitzung") {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(image.fileName, systemImage: "cpu.fill").font(.headline)
                            Text("SHA-256: \(image.sha256)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text(image.androidBootID == nil
                                 ? "Fastboot hat den Start angenommen. Der Android-Start wird beim nächsten Geräte-Refresh erfasst."
                                 : "Laut Fastboot-Startprotokoll für den aktuellen Android-Start geladen. Wird nach einem Neustart automatisch entfernt.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Gestartet: \(image.startedAt.formatted(date: .abbreviated, time: .shortened)) · Build \(image.build)")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                DisclosureGroup("Android-Einstellungen · optionale Schnellzugriffe") {
                    VStack(alignment: .leading, spacing: 10) {
                        InfoHint("Die App prüft zuerst, ob Android die jeweilige Intent-Aktion auf diesem Build auflösen kann. Nicht verfügbare Seiten führen zur allgemeinen Einstellungsübersicht.")
                        ForEach(SettingsAction.all) { action in
                            let availability = model.descriptor?.settingsActions.first(where: { $0.actionID == action.id })
                            HStack(spacing: 10) {
                                Image(systemName: availability?.isAvailable == true ? "checkmark.circle.fill" : "questionmark.circle")
                                    .foregroundStyle(availability?.isAvailable == true ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.title).fontWeight(.medium)
                                    Text(availability?.resolvedComponent ?? "Nicht auflösbar oder noch nicht geprüft")
                                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                Button("Öffnen") { Task { await model.openSystemSettings(action.id) } }
                                    .disabled(model.isBusy || !model.canWorkWithDevice)
                            }
                            .help(action.help)
                            .padding(.vertical, 3)
                        }
                        InfoHint("Diese Aktionen öffnen Android-Seiten; die App ändert keine geschützten oder globalen Einstellungen.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }

                GroupBox("Offizieller Firmware-Assistent") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let guide = model.firmwareGuide {
                            Label(guide.title, systemImage: "checkmark.seal")
                                .font(.headline)
                            if guide.match == .possibleModel {
                                Label("Gerätemodell nur teilweise erkannt. Vor einem Update Modell, Region und Variante auf der Herstellerseite manuell abgleichen.", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("Modellkennung passt zur Gerätefamilie. Bitte Firmwarevariante trotzdem auf der Herstellerseite abgleichen.")
                                    .foregroundStyle(.secondary)
                            }
                            LabeledContent("Gerätemeldung", value: softwareIdentity)
                            if let release = guide.listedRelease {
                                LabeledContent("Herstellerhinweis", value: release)
                            }
                            LabeledContent("Quelle zuletzt geprüft", value: guide.sourceCheckedAt)
                            Text(guide.guidance).fixedSize(horizontal: false, vertical: true)
                            Button("Offizielle \(guide.manufacturer)-Update-Seite öffnen") { model.openFirmwareGuide() }
                            Divider()
                            Text("Paket-Prüfsumme").font(.headline)
                            InfoHint("Wähle das Paket nur, wenn es direkt aus der offiziellen Quelle stammt. Vergleiche den Hersteller-SHA-256, falls veröffentlicht. Ein allein berechneter lokaler Hash prüft spätere Dateigleichheit, aber nicht die Echtheit.")
                            HStack {
                                Button("Lokales Updatepaket prüfen…") { showFirmwarePicker = true }
                                    .disabled(model.isBusy)
                                if let name = model.firmwareFileName { Text(name).lineLimit(1).foregroundStyle(.secondary) }
                            }
                            TextField("Offizieller SHA-256 (optional)", text: $model.officialFirmwareSHA256)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                            if let result = model.firmwareChecksumResult {
                                Text(result)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(result.contains("NICHT") ? .red : .secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            Label("Die App startet keinen Flash-, Recovery-, Sideload- oder OTA-Befehl. Setze das Update ausschließlich nach der offiziellen Anleitung am Gerät fort.", systemImage: "hand.raised.fill")
                                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            if guide.id == "retroid-flip-2" {
                                Divider()
                                DisclosureGroup("Erweitert · Flip 2 Overclock (Community-Boot-Image)") {
                                    VStack(alignment: .leading, spacing: 9) {
                                        Label("Die Communityquelle warnt vor Root/Garantieverlust. Die Beschreibung von `fastboot boot` als „ohne Root“ ist dadurch nicht bestätigt; ein modifiziertes Boot-Image wird im laufenden System ausgeführt.", systemImage: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                                        InfoHint("Freigabe nur für Flip 2 Snapdragon, Firmware 1.0.0.130 und den exakt benannten 905-OC-Boot-Image-Satz. Das Image wird nicht auf eine Partition geschrieben. Ein lokaler Hash weist die Herkunft nicht nach.")
                                        if let url = model.overclockImageURL {
                                            Text(url.path).font(.system(.caption, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                                            if let inspection = model.overclockImageInspection {
                                                Label(inspection.isAndroidBootImage ? "Android-Boot-Image erkannt" : "Kein gültiges Android-Boot-Image erkannt", systemImage: inspection.isAndroidBootImage ? "checkmark.circle.fill" : "xmark.circle.fill")
                                                    .foregroundStyle(inspection.isAndroidBootImage ? .green : .red)
                                                Text("Lokaler SHA-256: \(inspection.sha256)").font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                                            } else {
                                                Button("Image prüfen") { Task { await model.inspectOverclockImage(url) } }.disabled(model.isBusy)
                                            }
                                        } else {
                                            Text("Kein Boot-Image gewählt.").foregroundStyle(.secondary)
                                        }
                                        HStack {
                                            Button("Boot-Image auswählen…") { showOverclockImagePicker = true }.disabled(model.isBusy)
                                            Button("Maintainer-Releases auf GitHub") {
                                                if let url = URL(string: "https://github.com/The412Banner/Banners-No-PC-Retroid-Overclock/releases") { NSWorkspace.shared.open(url) }
                                            }
                                            if !model.fastbootAvailable {
                                                Text("fastboot fehlt in Android Platform Tools").font(.caption).foregroundStyle(.orange)
                                            }
                                            Spacer()
                                            if model.overclockFastbootReady {
                                                Button("Fastboot normal neu starten") { Task { await model.rebootFastbootDeviceToAndroid() } }
                                                    .disabled(model.isBusy)
                                            }
                                        }
                                        if !model.flip2OverclockBuildMatches {
                                            Label("Geräte-/Buildprüfung nicht erfüllt. Die Funktion bleibt gesperrt.", systemImage: "lock.fill").foregroundStyle(.secondary)
                                        }
                                        Button(model.overclockFastbootReady ? "Geprüftes Image einmalig starten…" : "Flip 2 in Fastboot neu starten…") {
                                            confirmOverclockAction = true
                                        }
                                        .disabled(model.isBusy || (model.overclockFastbootReady ? !model.canBootOverclockImage : !model.canEnterOverclockFastboot))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                }
                            }
                        } else {
                            ContentUnavailableView("Kein verifizierter Herstellerweg für dieses Modell", systemImage: "questionmark.folder", description: Text("Verbinde ein Retroid Pocket Flip 2 oder ANBERNIC RG Rotate. Unbekannte Geräte erhalten keinen Firmwarelink aus einer geratenen Zuordnung."))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            .padding(22)
        }
        .fileImporter(isPresented: $showFirmwarePicker, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { Task { await model.selectFirmwareFile(url) } }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showOverclockImagePicker, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { Task { await model.inspectOverclockImage(url) } }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .onAppear {
            if let url = model.overclockImageURL, model.overclockImageInspection == nil {
                Task { await model.inspectOverclockImage(url) }
            }
        }
        .alert("Overclock-Aktion bestätigen", isPresented: $confirmOverclockAction) {
            if model.overclockFastbootReady && model.canBootOverclockImage {
                Button("Image einmalig starten", role: .destructive) { Task { await model.bootOverclockImageForThisSession() } }
            } else if !model.overclockFastbootReady {
                Button("In den Bootloader starten") { Task { await model.enterOverclockFastboot() } }
            } else {
                Button("Schließen", role: .cancel) { }
            }
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text(model.overclockFastbootReady
                 ? "Fastboot-Seriennummer: \(model.overclockFastbootSerial ?? "unbekannt"). Das lokale, nicht herstellerverifizierte Boot-Image wird ausgeführt. Die Quelle weist auf Root und mögliche Garantieauswirkungen hin."
                 : "Das Gerät wird neu gestartet. Vor dem Image-Start prüft die App erneut Seriennummer, Dateihash und Boot-Image-Format. Das ist noch kein Start des Images.")
        }
    }

    private var softwareIdentity: String {
        guard let device = model.descriptor else { return "Kein verbundenes Gerät" }
        return "Android \(device.androidVersion) · API \(device.apiLevel) · Build \(device.build)"
    }
}

private struct AppsLauncherView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAPKPicker = false
    @State private var showWallpaperPicker = false
    @State private var frontendChoice = ""
    @State private var confirmInstall = false
    @State private var confirmDirectInstall = false
    @State private var confirmHomeLauncherChange = false
    @State private var appSearch = ""
    @State private var packagePendingRemoval: InstalledPackage?

    private var device: DeviceDescriptor? { model.descriptor }

    private var backupableFrontends: [LauncherOption] {
        LauncherOption.recommended.filter { option in
            !option.dataFolders.isEmpty && device?.packages.contains(where: { $0.packageName == option.packageName }) == true
        }
    }
    private var chosenFrontend: LauncherOption? {
        backupableFrontends.first { $0.packageName == frontendChoice } ?? backupableFrontends.first
    }

    @ViewBuilder
    private var frontendDataBox: some View {
        if let option = chosenFrontend {
            GroupBox("Frontend-Daten sichern und wiederherstellen") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("Frontend", selection: Binding(get: { option.packageName }, set: { frontendChoice = $0; model.frontendEntries = []; model.frontendScanMessage = nil })) {
                            ForEach(backupableFrontends) { Text($0.name).tag($0.packageName) }
                        }.frame(maxWidth: 260)
                        Button("Daten suchen", systemImage: "magnifyingglass") { Task { await model.scanFrontendData(option) } }
                            .disabled(model.isBusy || !model.canWorkWithDevice)
                        Spacer()
                        Button("Sicherung wiederherstellen…", systemImage: "arrow.uturn.backward") { chooseFrontendBackup() }
                            .disabled(model.isBusy || !model.canWorkWithDevice)
                    }
                    if let message = model.frontendScanMessage { Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    if !model.frontendEntries.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(model.frontendEntries) { entry in
                                Toggle(isOn: Binding(
                                    get: { model.frontendSelection.contains(entry.path) },
                                    set: { on in if on { model.frontendSelection.insert(entry.path) } else { model.frontendSelection.remove(entry.path) } }
                                )) {
                                    HStack {
                                        Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(.secondary)
                                        Text(entry.name)
                                        Spacer()
                                        Text(entry.sizeBytes.humanBytes).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 6)
                                Divider()
                            }
                        }
                        HStack {
                            Text("Große Medienordner sind vorab abgewählt.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Auf dem Mac sichern…", systemImage: "square.and.arrow.down") { backupFrontend(option) }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isBusy || model.frontendSelection.isEmpty)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }

    private func backupFrontend(_ option: LauncherOption) {
        let panel = NSSavePanel()
        panel.title = "\(option.name)-Daten sichern"
        panel.message = "Wähle Name und Ort des Ordners für die Sicherung."
        panel.prompt = "Sichern"
        panel.nameFieldStringValue = "\(option.name) Sicherung"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            if let saved = await model.backupFrontendData(option, to: directory) { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
        }
    }

    private func chooseFrontendBackup() {
        let panel = NSOpenPanel()
        panel.title = "Frontend-Sicherung wählen"
        panel.message = "Wähle den Ordner einer früheren Sicherung."
        panel.prompt = "Wählen"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await model.prepareFrontendRestore(from: folder) }
    }

    private var frontendRestoreMessage: String {
        guard let plan = model.frontendRestorePlan else { return "" }
        let date = plan.manifest.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(plan.manifest.items.count) Eintrag/Einträge aus der Sicherung vom \(date). \(plan.existing.count) davon gibt es auf dem Gerät schon; die aktuelle Version wandert in den Papierkorb des Geräts und wird durch die gesicherte ersetzt. Schließe das Frontend vorher auf dem Handheld."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("APK installieren oder aktualisieren") {
                    VStack(alignment: .leading, spacing: 12) {
                        InfoHint("Wähle eine APK oder einen vollständigen Split-APK-Satz. Vor der Installation prüft die App Paketname, Version, SHA-256 und Signatur gegen die installierte App.")
                        if !model.apkToolsAvailable {
                            Label("aapt/apksigner fehlen. Einzelne APKs können direkt installiert werden; Android prüft Signatur und Update-Kompatibilität. Für Split-APKs und die lokale Paket-/Versionsvorschau installiere Android SDK Build-Tools.", systemImage: "info.circle")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Button(model.apkToolsAvailable ? "APK-Dateien auswählen…" : "Eine APK auswählen…") { showAPKPicker = true }
                                .disabled(model.isBusy || !model.canWorkWithDevice)
                            if let plan = model.apkPlan {
                                Text("\(plan.packageName) · \(plan.artifacts.count) Datei(en)").foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.apkPlan != nil {
                                Button("Prüfen verwerfen") { model.discardAPKPlan() }
                            }
                        }
                        if let plan = model.apkPlan { installPlan(plan) }
                        if let preview = model.directAPKPreview {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(preview.fileName).fontWeight(.medium)
                                Text("SHA-256  \(preview.sha256)").font(.system(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                                Text("Paketname und Version werden vorab nicht ausgelesen. Android verweigert inkompatible Signaturen und Updates.")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("APK installieren…") { confirmDirectInstall = true }
                                        .disabled(model.isBusy)
                                    Button("Verwerfen") { model.discardDirectAPKPreview() }
                                        .disabled(model.isBusy)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                GroupBox("Android Home-Launcher") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Aktueller Launcher")
                                    .font(.headline)
                                Text(device?.currentHomeActivity?.displayName ?? "Nicht ermittelt")
                                    .font(.title3)
                                    .help(device?.currentHomeActivity?.componentName ?? "")
                            }
                            Spacer()
                            Button("Status aktualisieren") { Task { await model.refreshLauncherInfo() } }
                                .disabled(model.isBusy || !model.canWorkWithDevice)
                        }
                        if let activities = device?.homeActivities, !activities.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Erkannte Home-Apps (\(activities.count))").font(.headline)
                                ForEach(activities) { activity in
                                    Label(activity.displayName, systemImage: activity.id == device?.currentHomeActivity?.id ? "checkmark.circle.fill" : "app")
                                        .foregroundStyle(activity.id == device?.currentHomeActivity?.id ? .green : .secondary)
                                        .help(activity.componentName)
                                }
                            }
                        } else {
                            Text("Keine Home-Apps konnten gelesen werden. Verbinde ein autorisiertes Gerät und aktualisiere den Status.")
                                .foregroundStyle(.secondary)
                        }
                        if device?.canSetHomeActivity == true {
                            Picker("Standard-Launcher", selection: Binding(
                                get: { model.selectedHomePackageName ?? "" },
                                set: { model.selectedHomePackageName = $0 }
                            )) {
                                ForEach(device?.homeActivities ?? []) { activity in
                                    Text(activity.displayName).tag(activity.packageName)
                                }
                            }
                            Button("Launcher remote als Standard setzen…") { confirmHomeLauncherChange = true }
                                .disabled(model.isBusy || !model.canWorkWithDevice || model.selectedHomePackageName == nil)
                            Text("Dieser Build unterstützt den AOSP-Paketmanagerbefehl. Die Auswahl wird erst nach Bestätigung ausgeführt.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Android Home-Auswahl am Gerät öffnen") { Task { await model.openHomeSettings() } }
                                .disabled(model.isBusy || !model.canWorkWithDevice || (device?.homeActivities.count ?? 0) < 2)
                            Text("Dieser Build bietet keinen erkannten Remote-Befehl; Android zeigt die Home-Auswahl zur Bestätigung am Handheld.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                GroupBox("Launcher & Frontends installieren") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(LauncherOption.recommended) { option in
                            let installed = device?.packages.contains(where: { $0.packageName == option.packageName }) == true
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(option.name).font(.headline)
                                        if installed { Label("Installiert", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                                    }
                                    Text(option.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                if option.githubRepository != nil && !installed {
                                    Button("Installieren", systemImage: "arrow.down.circle.fill") {
                                        Task {
                                            await model.installLauncher(option)
                                            if model.apkPlan != nil { confirmInstall = true }
                                            else if model.directAPKPreview != nil { confirmDirectInstall = true }
                                        }
                                    }
                                    .buttonStyle(.borderedProminent).controlSize(.small)
                                    .disabled(model.isBusy || !model.canWorkWithDevice)
                                }
                                Button("Website", systemImage: "safari") { NSWorkspace.shared.open(option.website) }.controlSize(.small)
                            }.padding(.vertical, 10)
                            if option.id != LauncherOption.recommended.last?.id { Divider() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }

                frontendDataBox

                GroupBox("Hintergrundbild") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Bild vom Mac als Hintergrund setzen").font(.headline)
                            Text("Das Bild wird übertragen. Den Zuschnitt und „Als Hintergrund festlegen“ bestätigst du danach am Handheld.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Bild wählen…", systemImage: "photo") { showWallpaperPicker = true }
                            .disabled(model.isBusy || !model.canWorkWithDevice)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }

                GroupBox("Installierte Apps · Speicher · Deinstallation") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("\(device?.packages.count ?? 0) Apps auf dem Gerät").font(.headline)
                            Spacer()
                            Button(model.appUpdatesBusy ? "Prüfung läuft…" : "Updates prüfen", systemImage: "arrow.down.circle") { Task { await model.checkAppUpdates() } }
                                .disabled(model.appUpdatesBusy || !model.canWorkWithDevice || (device?.packages.isEmpty ?? true))
                            TextField("App oder Paket suchen", text: $appSearch)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                            Button("Aktualisieren") { Task { await model.refresh() } }
                                .disabled(model.isBusy || !model.canWorkWithDevice)
                        }
                        if model.appUpdatesBusy { Label("Offizielle Updatequellen werden geprüft…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary) }
                        if let packages = device?.packages {
                            let filtered = packages.filter {
                                appSearch.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(appSearch) || $0.packageName.localizedCaseInsensitiveContains(appSearch)
                            }.sorted {
                                switch ($0.storageBytes, $1.storageBytes) {
                                case let (left?, right?): return left == right ? $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending : left > right
                                case (_?, nil): return true
                                case (nil, _?): return false
                                case (nil, nil): return $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
                                }
                            }
                            ForEach(filtered) { package in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(package.displayTitle).fontWeight(.medium)
                                            if package.isEmulator == true { Text("Emulator").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2).background(.blue.opacity(0.14), in: Capsule()) }
                                            Text(package.isSystemApp == true ? "System" : "Nutzer-App")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Text(package.packageName).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                        HStack(spacing: 8) {
                                            Text("Version") + Text(" ") + Text(package.versionName ?? package.versionCode.map(String.init) ?? NSLocalizedString("unbekannt", comment: "Unknown version"))
                                            if let available = package.updateAvailable {
                                                Label {
                                                    if available { Text("Update verfügbar") + Text(" · \(package.updateVersionName ?? "")") }
                                                    else { Text("Aktuell") + Text(" · \(package.updateSourceName ?? "Quelle")") }
                                                } icon: { Image(systemName: available ? "arrow.down.circle.fill" : "checkmark.circle") }
                                                    .foregroundStyle(available ? .orange : .secondary)
                                                if let url = package.updateSourceURL {
                                                    Link(package.updateSourceName ?? "Quelle", destination: url)
                                                }
                                            } else if package.updateChecked == true {
                                                if let release = package.updateVersionName {
                                                    Text(String.localizedStringWithFormat(NSLocalizedString("Release gefunden · %@, Versionen nicht direkt vergleichbar", comment: "Release without comparable installed version"), release))
                                                } else {
                                                    Text(package.versionName == nil ? "Installierte Version fehlt" : "Updatequelle nicht abrufbar")
                                                }
                                                if let url = package.updateSourceURL { Link(package.updateSourceName ?? "Quelle", destination: url) }
                                            }
                                        }
                                        .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    if package.updateAvailable == true {
                                        if model.signatureMismatchPackages.contains(package.packageName) {
                                            Label("Signatur passt nicht", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                                                .help("Diese Quelle signiert anders als deine installierte App. Ein Update ist nur nach Deinstallation möglich (Daten gehen verloren).")
                                        } else if package.updateDownloadURL != nil {
                                            Button("Update laden", systemImage: "arrow.down.circle.fill") {
                                                Task {
                                                    await model.downloadUpdate(package)
                                                    if model.apkPlan != nil { confirmInstall = true }
                                                    else if model.directAPKPreview != nil { confirmDirectInstall = true }
                                                }
                                            }
                                            .buttonStyle(.borderedProminent).controlSize(.small)
                                            .help("Lädt \(package.updateAssetName ?? "die APK") von der offiziellen Quelle und prüft sie vor der Installation.")
                                            .disabled(model.isBusy || !model.canWorkWithDevice)
                                        }
                                        if package.updateDownloadURL == nil || model.signatureMismatchPackages.contains(package.packageName), let site = package.updateSourceURL {
                                            Button("Website öffnen", systemImage: "safari") { NSWorkspace.shared.open(site) }
                                                .controlSize(.small)
                                                .help(package.updateDownloadURL == nil ? "Für diese App gibt es keinen direkten APK-Download. Lade das Update auf der Website der Quelle." : "Quelle im Browser öffnen")
                                        }
                                    }
                                    Text(package.storageBytes.map(\.humanBytes) ?? "Nicht ermittelt")
                                        .font(.system(.callout, design: .rounded).monospacedDigit())
                                        .foregroundStyle(package.storageBytes == nil ? .secondary : .primary)
                                        .frame(minWidth: 100, alignment: .trailing)
                                    Button(package.isSystemApp == true ? "Für Benutzer entfernen" : "Deinstallieren", systemImage: "trash") {
                                        packagePendingRemoval = package
                                    }
                                    .labelStyle(.iconOnly)
                                    .help(package.isSystemApp == true ? "System-App für Benutzer 0 entfernen" : "App deinstallieren")
                                    .tint(.red)
                                    .disabled(model.isBusy || !model.canWorkWithDevice)
                                }
                                .padding(.vertical, 4)
                                if package.id != filtered.last?.id { Divider() }
                            }
                            if filtered.isEmpty { Text("Keine passenden Apps.").foregroundStyle(.secondary) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
            .padding(22)
        }
        .fileImporter(isPresented: $showWallpaperPicker, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { Task { await model.setWallpaper(url) } }
        }
        .fileImporter(isPresented: $showAPKPicker, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                if model.apkToolsAvailable {
                    Task { await model.prepareAPKUpdate(urls); confirmInstall = model.apkPlan != nil }
                } else {
                    model.prepareDirectAPKInstall(urls)
                }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            packagePendingRemoval?.isSystemApp == true ? "System-App für Benutzer 0 entfernen?" : "App deinstallieren?",
            isPresented: Binding(get: { packagePendingRemoval != nil }, set: { if !$0 { packagePendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            if let package = packagePendingRemoval {
                Button(package.isSystemApp == true ? "Für Benutzer entfernen" : "Deinstallieren", role: .destructive) {
                    Task { await model.removeInstalledApp(package); packagePendingRemoval = nil }
                }
            }
            Button("Abbrechen", role: .cancel) { packagePendingRemoval = nil }
        } message: {
            if let package = packagePendingRemoval {
                Text(package.isSystemApp == true
                     ? "\(package.displayTitle) (\(package.packageName)) wird für Benutzer 0 entfernt. Die vorinstallierte Systemkopie bleibt im Geräteabbild."
                     : "\(package.displayTitle) (\(package.packageName)) und die zugehörigen App-Daten werden von diesem Gerät deinstalliert.")
            }
        }
        .alert("Sicherung zurückspielen?", isPresented: Binding(get: { model.frontendRestorePlan != nil }, set: { if !$0 { model.frontendRestorePlan = nil } })) {
            Button("Zurückspielen") { Task { await model.applyFrontendRestore() } }
            Button("Abbrechen", role: .cancel) { model.frontendRestorePlan = nil }
        } message: { Text(frontendRestoreMessage) }
        .alert("APK installieren?", isPresented: $confirmInstall) {
            Button("Installieren / aktualisieren") { Task { await model.installAPKPlan() } }
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text(installConfirmation)
        }
        .confirmationDialog("APK direkt installieren?", isPresented: $confirmDirectInstall, titleVisibility: .visible) {
            Button("Installieren / aktualisieren") { Task { await model.installDirectAPK() } }
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text(directInstallConfirmation)
        }
        .confirmationDialog("Standard-Launcher ändern?", isPresented: $confirmHomeLauncherChange, titleVisibility: .visible) {
            Button("Als Standard setzen") {
                if let packageName = model.selectedHomePackageName { Task { await model.setHomeLauncher(packageName) } }
            }
            Button("Abbrechen", role: .cancel) { }
        } message: { Text("Android setzt \(model.selectedHomePackageName ?? "die ausgewählte Home-App") als Standard. Die bisherige Home-App bleibt installiert und kann später wieder ausgewählt werden.") }
        .task(id: model.selectedSerial) {
            guard model.canWorkWithDevice, model.descriptor?.connection.serial == model.selectedSerial else { return }
            await model.checkEmulatorUpdates()
        }
    }

    @ViewBuilder
    private func installPlan(_ plan: APKInstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            LabeledContent("Paket", value: plan.packageName)
            LabeledContent("Zielversion", value: "\(plan.versionName ?? "unbekannt") (\(plan.versionCode))")
            LabeledContent("Installiert", value: plan.installedVersionCode.map { "\(plan.installedVersionName ?? "unbekannt") (\($0))" } ?? "Noch nicht installiert")
            LabeledContent("Signatur SHA-256", value: plan.signerSHA256.joined(separator: ", "))
            ForEach(plan.artifacts) { artifact in
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact.url.lastPathComponent).fontWeight(.medium)
                    Text("SHA-256  \(artifact.sha256)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Button(plan.isUpdate ? "Aktualisierung bestätigen…" : "Installation bestätigen…") { confirmInstall = true }
                .disabled(model.isBusy)
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var installConfirmation: String {
        guard let plan = model.apkPlan else { return "Kein geprüfter APK-Plan vorhanden." }
        let verb = plan.isUpdate ? "wird aktualisiert" : "wird installiert"
        return "\(plan.packageName) \(verb) auf Version \(plan.versionName ?? "unbekannt") (\(plan.versionCode)). \(plan.artifacts.count) APK-Datei(en), Signatur SHA-256: \(plan.signerSHA256.joined(separator: ", "))."
    }

    private var directInstallConfirmation: String {
        guard let preview = model.directAPKPreview else { return "Keine APK ausgewählt." }
        return "\(preview.fileName) · SHA-256 \(preview.sha256). Android prüft Paket, Signatur und Update-Kompatibilität. Installiere APKs nur aus einer vertrauenswürdigen Quelle."
    }
}

private struct RomLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var selectedConsole = ""
    @State private var selectedEmulator = ""
    @State private var unknownDiscConsole = ""
    @State private var sort: RomSortOption = .name
    @State private var showROMImporter = false
    @State private var renameTarget: RomGame?
    @State private var deleteTarget: RomGame?
    @State private var coverTarget: RomGame?
    @State private var coverVersion = 0

    private let knownDiscConsoles = ["PlayStation 2", "PlayStation", "PSP", "GameCube", "Wii", "Nintendo 64", "Dreamcast"]
    private func platform(for game: RomGame) -> String { game.platform == "Unbekannt (ISO/Disc)" && !unknownDiscConsole.isEmpty ? unknownDiscConsole : game.platform }
    private var consoles: [String] { Array(Set(model.romGames.map { platform(for: $0) })).sorted() }
    private var installedEmulators: [InstalledPackage] { (model.descriptor?.packages ?? []).filter { $0.isEmulator == true } }

    private var visibleGames: [RomGame] {
        let filtered = model.romGames.filter { game in
            let matchesSearch = search.isEmpty || game.title.localizedCaseInsensitiveContains(search) || game.platform.localizedCaseInsensitiveContains(search) || game.fileName.localizedCaseInsensitiveContains(search)
            let matchesConsole = selectedConsole.isEmpty || platform(for: game) == selectedConsole
            let matchesEmulator: Bool
            if selectedEmulator.isEmpty { matchesEmulator = true }
            else if let emulator = installedEmulators.first(where: { $0.packageName == selectedEmulator }) {
                let supported = EmulatorCatalog.compatiblePlatforms(packageName: emulator.packageName)
                matchesEmulator = supported.contains("*") || supported.contains(platform(for: game))
            } else { matchesEmulator = false }
            return matchesSearch && matchesConsole && matchesEmulator
        }
        let projectMatches = model.romProjectMatches
        return filtered.sorted { left, right in
            switch sort {
            case .name: return left.title.localizedStandardCompare(right.title) == .orderedAscending
            case .console:
                if platform(for: left) != platform(for: right) { return platform(for: left).localizedStandardCompare(platform(for: right)) == .orderedAscending }
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            case .size: return left.sizeBytes == right.sizeBytes ? left.title.localizedStandardCompare(right.title) == .orderedAscending : left.sizeBytes > right.sizeBytes
            case .recompilation:
                func hasRecomp(_ game: RomGame) -> Bool { projectMatches[game.path]?.contains(where: { $0.method == .recompilation }) == true }
                if hasRecomp(left) != hasRecomp(right) { return hasRecomp(left) }
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Picker("Speicher", selection: Binding(get: { model.romVolumeID ?? "" }, set: { model.romVolumeID = $0.isEmpty ? nil : $0 })) {
                        ForEach(model.descriptor?.volumes ?? []) { volume in Text(volume.name).tag(volume.id) }
                    }.frame(maxWidth: 190)
                    TextField("ROM-Ordner auf dem Gerät", text: $model.romFolderPath).textFieldStyle(.roundedBorder)
                    Button("Scannen", systemImage: "magnifyingglass") { Task { await model.scanROMs() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || !model.canWorkWithDevice || model.romFolderPath.isEmpty || model.romVolumeID == nil)
                    Button("ROMs hinzufügen…", systemImage: "plus") { showROMImporter = true }
                        .disabled(model.isBusy || !model.canWorkWithDevice || model.romFolderPath.isEmpty || model.romVolumeID == nil)
                        .help("Dateien vom Mac in den ROM-Ordner übertragen. Du kannst sie auch auf dieses Fenster ziehen.")
                }
                HStack(spacing: 10) {
                    TextField("Spiele suchen", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 230)
                    Picker("Konsole", selection: $selectedConsole) {
                        Text("Alle Konsolen").tag("")
                        ForEach(consoles, id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: 190)
                    Picker("Emulator", selection: $selectedEmulator) {
                        Text("Alle Emulatoren").tag("")
                        ForEach(installedEmulators) { Text($0.displayTitle).tag($0.packageName) }
                    }.frame(maxWidth: 210)
                    Picker("Sortierung", selection: $sort) {
                        ForEach(RomSortOption.allCases) { Text($0.title).tag($0) }
                    }.frame(maxWidth: 165)
                    Spacer(minLength: 4)
                    Text("\(visibleGames.count) / \(model.romGames.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Button { Task { await model.refreshROMProjects(forceRefresh: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Projektkataloge aktualisieren").disabled(model.romGames.isEmpty || model.romCatalogBusy)
                    InfoHint("Android-Support wird nur dann bestätigt, wenn das Projekt Android ausdrücklich nennt. Cover stammen von den Libretro Thumbnails.")
                }
                if model.romGames.contains(where: { $0.platform == "Unbekannt (ISO/Disc)" }) {
                    Picker("ISO-Konsole zuordnen", selection: $unknownDiscConsole) {
                        Text("Nicht festgelegt").tag("")
                        ForEach(knownDiscConsoles, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 235)
                    .help("Ordnet mehrdeutige Disc-Dateien für Cover und Filter manuell einer Konsole zu.")
                }
                if model.romCatalogBusy { Label("Projektkataloge werden geprüft…", systemImage: "arrow.triangle.2.circlepath").font(.caption).foregroundStyle(.secondary) }
                if let message = model.romCatalogMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 22)
            if model.romGames.isEmpty {
                ContentUnavailableView("Noch keine Spiele eingelesen", systemImage: "opticaldiscdrive", description: Text("Wähle einen ROM-Ordner auf dem Gerät aus und starte den Scan. Neue Spiele kannst du mit „ROMs hinzufügen“ oder per Drag & Drop übertragen.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleGames.isEmpty {
                ContentUnavailableView("Keine passenden Spiele", systemImage: "line.3.horizontal.decrease.circle", description: Text("Passe Suche oder Filter an.")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 290), spacing: 14)], alignment: .leading, spacing: 14) {
                        ForEach(visibleGames) { game in
                            RomGameCard(game: game, effectivePlatform: platform(for: game), projects: model.romProjectMatches[game.path], coverVersion: coverVersion,
                                        onRename: { renameTarget = game }, onDelete: { deleteTarget = game }, onCover: { coverTarget = game })
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 12)
        .fileImporter(isPresented: $showROMImporter, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.prepareROMImport(urls) } }
        }
        .sheet(isPresented: Binding(get: { model.romImport != nil }, set: { if !$0 { model.romImport = nil } })) { ROMImportSheet() }
        .sheet(item: $renameTarget) { game in
            RenameROMSheet(game: game) { name in Task { await model.renameROM(game, to: name) } }
        }
        .sheet(item: $coverTarget) { game in
            CoverSearchSheet(game: game, platform: platform(for: game)) { url in
                RomCoverStore.set(url, for: game.path)
                RomCoverLoader.forget(path: game.path)
                coverVersion += 1
            }
        }
        .confirmationDialog("ROM löschen?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), titleVisibility: .visible, presenting: deleteTarget) { game in
            Button("In Papierkorb verschieben") { model.confirmAgain("Wirklich in den Papierkorb verschieben?", "\(game.title) und zugehörige Track-Dateien werden auf dem Handheld in den Papierkorb verschoben.", label: "Ja, verschieben") { Task { await model.deleteROM(game, permanently: false) } } }
            Button("Endgültig löschen", role: .destructive) { model.confirmAgain("Wirklich endgültig löschen?", "\(game.title) wird dauerhaft gelöscht. Zur Sicherheit noch einmal: Das Löschen kann nicht rückgängig gemacht werden.") { Task { await model.deleteROM(game, permanently: true) } } }
            Button("Abbrechen", role: .cancel) { }
        } message: { game in
            Text("\(game.title) und zugehörige Track-Dateien werden vom Gerät entfernt. Im Papierkorb bleiben sie auf dem Handheld erhalten, bis du sie dort löschst.")
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canWorkWithDevice, !model.romFolderPath.isEmpty else { return false }
            Task { await model.prepareROMImport(urls.filter(\.isFileURL)) }
            return true
        }
        .task(id: model.selectedSerial) {
            guard model.canWorkWithDevice else { return }
            let serial = model.selectedSerial ?? ""
            if model.romGames.isEmpty,
               let volumeID = UserDefaults.standard.string(forKey: "HandheldManager.romVolume.\(serial)"),
               UserDefaults.standard.string(forKey: "HandheldManager.romPath.\(serial)") != nil {
                model.romVolumeID = volumeID
            }
        }
    }
}

private enum RomSortOption: String, CaseIterable, Identifiable {
    case name, console, size, recompilation
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return NSLocalizedString("Name", comment: "ROM sort option")
        case .console: return NSLocalizedString("Konsole", comment: "ROM sort option")
        case .size: return NSLocalizedString("Größe", comment: "ROM sort option")
        case .recompilation: return NSLocalizedString("Recompilation", comment: "ROM sort option")
        }
    }
}

private struct RomGameCard: View {
    @StateObject private var cover = RomCoverLoader()
    let game: RomGame
    let effectivePlatform: String
    let projects: [RomProjectMatch]?
    let coverVersion: Int
    let onRename: () -> Void
    let onDelete: () -> Void
    let onCover: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor))
                if let image = cover.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(10)
                } else if cover.isLoading {
                    ProgressView()
                } else {
                    VStack(spacing: 7) {
                        Image(systemName: "opticaldiscdrive").font(.system(size: 34, weight: .light))
                        Text("Cover nicht gefunden").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 172)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if game.groupedPaths.count > 1 {
                    Label(String.localizedStringWithFormat(NSLocalizedString("%lld Discdateien", comment: "Grouped ROM disc or track files"), game.groupedPaths.count), systemImage: "square.stack.3d.up")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                        .help(NSLocalizedString("Zusammengefasste Disc- oder Trackdateien", comment: "Grouped ROM files"))
                }
            }
            .task(id: "\(game.path)|\(effectivePlatform)|\(coverVersion)") {
                await cover.load(RomGame(path: game.path, sizeBytes: game.sizeBytes, platform: effectivePlatform, fileExtension: game.fileExtension), force: coverVersion > 0)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(game.title).font(.headline).lineLimit(2).frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                HStack {
                    Label(effectivePlatform, systemImage: "gamecontroller").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    Text(game.sizeBytes.humanBytes).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
                if let projects, !projects.isEmpty {
                    Divider()
                    ForEach(projects.prefix(2)) { project in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: project.method == .recompilation ? "checkmark.seal.fill" : "hammer.fill")
                                .foregroundStyle(project.method == .recompilation ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.projectTitle).font(.caption.weight(.medium)).lineLimit(1)
                                Text(project.androidStatus.localizedDescription).font(.caption2).foregroundStyle(project.androidStatus == .supported ? .green : .secondary)
                            }
                            Spacer(minLength: 0)
                            Link(destination: project.sourceURL) { Image(systemName: "arrow.up.right.square") }
                                .help(project.sourceTitle)
                        }
                    }
                } else if projects != nil {
                    Label("Keine Projekt-Recompilation gefunden", systemImage: "minus.circle")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Label("Projektstatus noch nicht geladen", systemImage: "clock")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 11)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.55)))
        .contextMenu {
            Button("Bearbeiten…", systemImage: "pencil", action: onRename).disabled(game.groupedPaths.count > 1)
            Button("Cover suchen…", systemImage: "photo.on.rectangle", action: onCover)
            Divider()
            Button("Löschen…", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

private struct ROMImportSheet: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let items = model.romImport ?? []
        VStack(alignment: .leading, spacing: 14) {
            Text("ROMs hinzufügen").font(.title2.weight(.semibold))
            Text("Jede Datei wird in den Ordner ihrer Konsole kopiert. Fehlt er, wird er angelegt.").foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                if !item.platform.isEmpty {
                                    Text(model.importTarget(for: item.platform)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                    if let allowed = RomLibraryService.validExtensions[item.platform], !allowed.contains(item.url.pathExtension.lowercased()) {
                                        Label("Endung .\(item.url.pathExtension) wird für diese Konsole nicht als Spiel erkannt.", systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                }
                            }
                            Spacer(minLength: 8)
                            Picker("Konsole", selection: Binding(get: { item.platform }, set: { model.setImportPlatform(item.id, $0) })) {
                                Text("Konsole wählen…").tag("")
                                ForEach(RomLibraryService.importConsoles, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().frame(width: 200)
                        }.padding(.vertical, 8)
                        Divider()
                    }
                }
            }.frame(minHeight: 120, maxHeight: 360)
            HStack {
                Button("Abbrechen") { model.romImport = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Hinzufügen") { Task { await model.confirmROMImport() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(items.contains { $0.platform.isEmpty } || model.isBusy)
            }
        }.padding(22).frame(width: 640)
    }
}

private struct RenameROMSheet: View {
    @Environment(\.dismiss) private var dismiss
    let game: RomGame
    let onSave: (String) -> Void
    @State private var name: String

    init(game: RomGame, onSave: @escaping (String) -> Void) {
        self.game = game
        self.onSave = onSave
        _name = State(initialValue: (game.fileName as NSString).deletingPathExtension)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ROM umbenennen").font(.title2.weight(.semibold))
            Text("Der Dateiname auf dem Gerät ändert sich. Die Endung .\((game.fileName as NSString).pathExtension) bleibt erhalten.").foregroundStyle(.secondary)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Umbenennen", action: save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name.contains("/"))
            }
        }.padding(22).frame(width: 460)
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !name.contains("/") else { return }
        onSave(name)
        dismiss()
    }
}

private struct CoverSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let game: RomGame
    let platform: String
    let onPick: (URL?) -> Void
    @State private var query: String
    @State private var results: [CoverCandidate] = []
    @State private var searching = false
    @State private var searched = false

    init(game: RomGame, platform: String, onPick: @escaping (URL?) -> Void) {
        self.game = game
        self.platform = platform
        self.onPick = onPick
        _query = State(initialValue: game.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cover suchen").font(.title2.weight(.semibold))
            HStack {
                TextField("Spielname", text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await search() } }
                Button("Suchen") { Task { await search() } }.disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Passe den Namen an, wenn nichts passt, zum Beispiel ohne Untertitel oder in englischer Schreibweise.").font(.caption).foregroundStyle(.secondary)
            if searching {
                ProgressView().frame(maxWidth: .infinity, minHeight: 160)
            } else if results.isEmpty && searched {
                ContentUnavailableView("Keine Cover gefunden", systemImage: "photo", description: Text(platform.hasPrefix("Unbekannt") ? "Ordne dem Spiel zuerst eine Konsole zu." : "Versuche einen kürzeren Namen."))
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                        ForEach(results) { item in
                            Button { onPick(item.url); dismiss() } label: {
                                VStack(spacing: 6) {
                                    AsyncImage(url: item.url) { image in image.resizable().aspectRatio(contentMode: .fit) } placeholder: { ProgressView() }
                                        .frame(height: 120)
                                    Text(item.name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                                }
                                .padding(8).frame(maxWidth: .infinity)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(minHeight: 200, maxHeight: 420)
            }
            HStack {
                Button("Automatisch zurücksetzen") { onPick(nil); dismiss() }.disabled(RomCoverStore.url(for: game.path) == nil)
                Spacer()
                Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22).frame(width: 640)
        .task { await search() }
    }

    private func search() async {
        searching = true
        results = await RomArtworkService.shared.search(query, platform: platform)
        searching = false
        searched = true
    }
}

private extension RomProjectMethod {
    var localizedDescription: String {
        switch self {
        case .recompilation: return NSLocalizedString("Recompilation", comment: "ROM project method")
        case .decompilation: return NSLocalizedString("Decompilation", comment: "ROM project method")
        case .port: return NSLocalizedString("Port / Rewrite", comment: "ROM project method")
        }
    }
}

private extension AndroidProjectStatus {
    var localizedDescription: String {
        switch self {
        case .supported: return NSLocalizedString("Android wird angegeben", comment: "ROM project Android status")
        case .notListed: return NSLocalizedString("Android nicht angegeben", comment: "ROM project Android status")
        case .notVerified: return NSLocalizedString("Nicht geprüft", comment: "ROM project Android status")
        }
    }
}

private struct EmulatorProfilesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showProfileImporter = false
    @State private var showConfigImporter = false
    @State private var showEditedConfigImporter = false
    @State private var configFiles: [URL] = []
    @State private var selectedDeviceConfigPaths: Set<String> = []
    @State private var selectedConfigVolumeID: String?
    @State private var profileName = "Emulatorprofil"
    @State private var confirmApply = false
    @State private var confirmRollback = false
    @State private var confirmEditedConfigUpload = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Config des ausgewählten Emulators") {
                    VStack(alignment: .leading, spacing: 8) {
                        InfoHint("Configs werden auf den zugänglichen Speicherorten des ausgewählten Emulators gesucht. Androids private /data/data-Sandbox bleibt geschützt.")
                        HStack {
                            Text("Emulator").fontWeight(.medium)
                            Picker("Emulator", selection: configPackageSelection) { packageOptions }
                                .labelsHidden().frame(maxWidth: 360)
                            Button { Task { await model.discoverEmulatorConfigFiles() } } label: {
                                Label("Configs suchen", systemImage: "magnifyingglass")
                            }
                                .disabled(model.isBusy || model.selectedPackage == nil || !model.canWorkWithDevice)
                        }
                        InfoHint("Die Suche listet erreichbare Dateien auf. Wähle Configs aus und speichere sie auf dem Mac. Der Upload nimmt eine zuvor gespeicherte und bearbeitete Config, prüft sie und sichert das Original vor dem Ersetzen.")
                        if model.discoveredConfigFiles.isEmpty {
                            Text("Noch keine Configs gesucht. Wähle einen Emulator und klicke auf „Configs suchen“.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            let selectedVolumeName = selectedConfigVolumeID.flatMap { id in model.descriptor?.volumes.first(where: { $0.id == id })?.name }
                            Text("\(model.discoveredConfigFiles.count) Configs · für \(model.selectedPackage?.displayTitle ?? "Emulator") · \(selectedVolumeName ?? "interner Speicher und microSD können gemischt sein") · \(selectedDeviceConfigPaths.count) ausgewählt")
                                .font(.caption).foregroundStyle(.secondary)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(model.discoveredConfigFiles) { entry in
                                        Toggle(isOn: deviceConfigSelection(entry.path)) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack(spacing: 6) {
                                                    Text(entry.priorityLabel.uppercased()).font(.caption2).foregroundStyle(.tint)
                                                    Text(entry.name).fontWeight(.medium)
                                                }
                                                Text("\(entry.size.humanBytes) · \(volumeName(for: entry.path) ?? "Speicher") · \(entry.path)")
                                                    .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                            }
                                        }
                                        .toggleStyle(.checkbox)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(maxHeight: 210).padding(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        }
                        HStack {
                            Button("Ausgewählte Configs auf dem Mac speichern…") { saveSelectedDeviceConfigs() }
                                .disabled(model.isBusy || selectedDeviceConfigPaths.isEmpty || !model.canWorkWithDevice)
                            Button { showEditedConfigImporter = true } label: {
                                Label("Config hochladen…", systemImage: "square.and.arrow.up")
                            }
                                .disabled(model.isBusy || !model.hasConfigRemoteMappings || !model.canWorkWithDevice)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }

                DisclosureGroup("Portables Profil (JSON) · Erweitert") {
                    VStack(alignment: .leading, spacing: 12) {
                        InfoHint("Ein JSON-Profil verpackt ausgewählte Config-Dateien samt Emulator-ID und Prüfsummen, damit du denselben Satz später wieder importieren und auf ein Gerät anwenden kannst. Für einzelne Configs genügt der direkte Laden-/Hochladen-Weg oben.")
                        HStack {
                            Button("JSON-Profil importieren…") { showProfileImporter = true }
                            Button("Lokale Config-Dateien auswählen…") { showConfigImporter = true }
                                .disabled(model.descriptor?.packages.isEmpty != false)
                            Text(configFiles.isEmpty ? "Keine Dateien ausgewählt" : "\(configFiles.count) Datei(en) ausgewählt")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Text("Ziel-Emulator").frame(width: 190, alignment: .leading)
                            Picker("Paket", selection: packageSelection) { packageOptions }
                                .labelsHidden().frame(maxWidth: 380)
                        }
                        HStack {
                            Text("Zielspeicher und Ordner").frame(width: 190, alignment: .leading)
                            Picker("Volume", selection: volumeSelection) {
                                ForEach(model.descriptor?.volumes ?? []) { volume in Text(volume.name).tag(volume.id) }
                            }.labelsHidden().frame(width: 180)
                                .help("Wählt internen Speicher oder microSD als Ziel für das Profil.")
                            TextField("Zielordner auf dem Gerät", text: $model.profileRoot).textFieldStyle(.roundedBorder)
                                .help("Config-Dateien werden relativ zu diesem Ordner auf das Gerät geschrieben.")
                        }
                        HStack {
                            Text("Profilname (JSON/Backup)").frame(width: 190, alignment: .leading)
                            TextField("Profilname", text: $profileName).textFieldStyle(.roundedBorder).frame(maxWidth: 380)
                                .help("Name zur Wiedererkennung im JSON-Profil und lokalen Backup.")
                        }
                        if let profile = model.profile {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text.magnifyingglass")
                                Text(profileSummary(profile))
                                    .lineLimit(1).textSelection(.enabled)
                            }.foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Profilvorschau erstellen") { Task { await model.previewProfile() } }
                                .disabled(model.profile == nil || model.selectedPackage == nil || model.selectedVolume == nil || model.isBusy)
                            Button("Profil aus Dateien erstellen") { createProfile() }
                                .disabled(configFiles.isEmpty || model.selectedPackage == nil)
                            Button("Profil exportieren…") { exportProfile() }.disabled(model.profile == nil)
                            Spacer()
                            Button("Anwenden…") { confirmApply = true }
                                .disabled(model.profileChanges.isEmpty || model.isBusy)
                            Button("Rollback…") { confirmRollback = true }
                                .disabled(!model.profileBackupAvailable || model.isBusy)
                        }
                        InfoHint("Ablauf: JSON importieren oder lokale Dateien auswählen und ein Profil erstellen → Ziel festlegen → Vorschau. Anwenden ist erst nach erfolgreicher Vorschau aktiv; Export ist erst mit geladenem oder erstelltem Profil verfügbar.")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }

                if !model.profileChanges.isEmpty {
                    GroupBox("Änderungsvorschau") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.profileChanges) { change in profileChangeRow(change) }
                            InfoHint("Beim Anwenden wird jede bestehende Datei lokal gesichert. Staging-Dateien werden vor dem Austausch per SHA-256 geprüft. Ein fehlgeschlagener Schritt löst Rollback aus.")
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }

            }.padding(20)
        }
        .onAppear {
            if model.profileRoot.isEmpty, let volume = model.selectedVolume { model.profileRoot = volume.path }
            if let package = model.selectedPackageName { Task { await model.choosePackage(package) } }
        }
        .onChange(of: model.selectedPackageName) { _, value in
            selectedDeviceConfigPaths = []
            selectedConfigVolumeID = nil
            model.discoveredConfigFiles = []
            Task { await model.choosePackage(value) }
        }
        .fileImporter(isPresented: $showProfileImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result { case .success(let urls): if let url = urls.first { model.selectProfileFile(url) }; case .failure(let error): model.errorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $showConfigImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result { case .success(let urls): configFiles = urls; case .failure(let error): model.errorMessage = error.localizedDescription }
        }
        .fileImporter(isPresented: $showEditedConfigImporter, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    await model.prepareEditedEmulatorConfig(url)
                    confirmEditedConfigUpload = model.configUploadPreview != nil
                }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .alert("Geänderte Config zurückspielen?", isPresented: $confirmEditedConfigUpload) {
            Button("Sichern und übertragen") { Task { await model.uploadEditedEmulatorConfig() } }
            Button("Abbrechen", role: .cancel) { model.discardEditedEmulatorConfigPreview() }
        } message: {
            Text(editedConfigUploadConfirmation)
        }
        .alert("Profil auf dem Gerät anwenden?", isPresented: $confirmApply) {
            Button("Sichern und anwenden") { Task { await model.applyProfile() } }
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text("\(model.profileChanges.count) Datei(en) für \(model.selectedPackageName ?? "") am Ziel \(model.profileRoot). Bestehende Dateien werden lokal gesichert.")
        }
        .alert("Letzte Profiländerung rückgängig machen?", isPresented: $confirmRollback) {
            Button("Rollback ausführen", role: .destructive) { Task { await model.rollbackProfile() } }
            Button("Abbrechen", role: .cancel) { }
        } message: {
            Text("Das letzte lokale Backup wird auf diesem Gerät wiederhergestellt. Neu angelegte Profildateien werden entfernt.")
        }
    }

    private func createProfile() {
        guard let package = model.selectedPackage else { return }
        do {
            _ = try model.createProfile(name: profileName, packageName: package.packageName, files: configFiles)
            configFiles = []
            model.statusMessage = "Generisches Profil erstellt. Wähle den Zielordner und erstelle eine Vorschau."
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func selectVolume(_ value: String) {
        model.selectedVolumeID = value
        if let volume = model.descriptor?.volumes.first(where: { $0.id == value }) {
            model.profileRoot = volume.path
        }
    }

    private func profileSummary(_ profile: EmulatorProfile) -> String {
        [profile.name, "Schema \(profile.schemaVersion)", "\(profile.files.count) Datei(en)", "für \(profile.packageName)"].joined(separator: " · ")
    }

    private func profileChangeRow(_ change: ProfileChange) -> some View {
        let icon = change.existing ? "arrow.triangle.2.circlepath" : "plus.circle"
        let tone: Color = change.existing ? .orange : .green
        let label = change.existing ? "Wird mit Backup ersetzt" : "Neue Datei"
        let size = Int64(change.size).humanBytes
        let hash = String(change.sha256.prefix(12))
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                Text(label + " · " + size + " · SHA-256 " + hash + "…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 3)
    }

    private var packageSelection: Binding<String> {
        Binding(
            get: { model.selectedPackageName ?? "" },
            set: { value in Task { await model.choosePackage(value.isEmpty ? nil : value) } }
        )
    }

    /// Choosing an emulator in the config box also starts the config search.
    private var configPackageSelection: Binding<String> {
        Binding(
            get: { model.selectedPackageName ?? "" },
            set: { value in
                Task {
                    await model.choosePackage(value.isEmpty ? nil : value)
                    if !value.isEmpty { await model.discoverEmulatorConfigFiles() }
                }
            }
        )
    }

    private var volumeSelection: Binding<String> {
        Binding(
            get: { model.selectedVolumeID ?? "" },
            set: { value in selectVolume(value) }
        )
    }

    private func exportProfile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(profileName.replacingOccurrences(of: " ", with: "-" )).handheld-profile.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.exportCurrentProfile(to: url) }
        catch { model.errorMessage = error.localizedDescription }
    }

    private func saveSelectedDeviceConfigs() {
        let paths = Array(selectedDeviceConfigPaths).sorted()
        guard !paths.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Emulator-Configs sichern"
        panel.message = "Wähle Name und Ort des Ordners, in dem die gesicherten Configs liegen sollen."
        panel.prompt = "Sichern"
        panel.nameFieldStringValue = "\(model.selectedPackage?.displayTitle ?? "Emulator") Configs"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            let exported = await model.exportCurrentConfigFiles(paths, to: directory)
            if !exported.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(exported) }
        }
    }

    private var editedConfigUploadConfirmation: String {
        guard let config = model.configUploadPreview else { return "Keine geänderte Config ausgewählt." }
        return "Quelle: \(config.preview.source)\nZiel: \(config.mapping.remotePath)\nGröße: \(config.preview.size.humanBytes)\nSHA-256: \(config.preview.sha256)\nDie bestehende Config wird vor dem Ersetzen lokal gesichert."
    }

    private func deviceConfigSelection(_ path: String) -> Binding<Bool> {
        Binding(
            get: { selectedDeviceConfigPaths.contains(path) },
            set: { selected in
                if selected {
                    let newVolumeID = volumeID(for: path)
                    if selectedConfigVolumeID != newVolumeID {
                        selectedDeviceConfigPaths.removeAll()
                        selectedConfigVolumeID = newVolumeID
                    }
                    selectedDeviceConfigPaths.insert(path)
                } else {
                    selectedDeviceConfigPaths.remove(path)
                    if selectedDeviceConfigPaths.isEmpty { selectedConfigVolumeID = nil }
                }
            }
        )
    }

    private func volumeID(for path: String) -> String? {
        model.descriptor?.volumes.first(where: { path.hasPrefix($0.path + "/") })?.id
    }

    private func volumeName(for path: String) -> String? {
        model.descriptor?.volumes.first(where: { path.hasPrefix($0.path + "/") })?.name
    }

    @ViewBuilder
    private var packageOptions: some View {
        let packages = model.descriptor?.packages ?? []
        ForEach(packages) { package in
            Text(package.isEmulator == true ? "\(package.displayTitle) · \(package.packageName)" : package.packageName).tag(package.packageName)
        }
    }
}

/// Replaces a paragraph of explanation with a small link that opens it in a popover.
private struct InfoHint: View {
    let text: LocalizedStringKey
    @State private var shown = false
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Button { shown.toggle() } label: { Label("Hinweis", systemImage: "info.circle") }
            .buttonStyle(.link).font(.caption)
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text).padding(14).frame(width: 340, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
    }
}

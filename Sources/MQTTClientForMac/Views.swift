import SwiftUI
import Charts
import AppKit
import UniformTypeIdentifiers

// MARK: - Main window

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showConnections = false
    @State private var showSubscriptions = false

    private func exportTree() {
        guard let data = model.exportJSON() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "mqtt-topics.json"
        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
        }
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            NavigationSplitView {
                TreePane(onConfigure: { showConnections = true })
                    .navigationSplitViewColumnWidth(min: 300, ideal: 420, max: 700)
            } detail: {
                DetailColumn()
            }
            .searchable(text: $model.filter, placement: .sidebar, prompt: "Filter topics and values")

            Divider()
            StatusBar()
        }
        .toolbar {
            ToolbarItem {
                Picker("Connection", selection: $model.activeProfileID) {
                    ForEach(model.profiles) { p in
                        Text(p.displayName).tag(Optional(p.id))
                    }
                }
                .frame(width: 180)
                .disabled(model.isBusy || model.isConnected || model.profiles.isEmpty)
            }
            ToolbarItem {
                Button(model.isConnected || model.isBusy ? "Disconnect" : "Connect",
                       systemImage: model.isConnected ? "bolt.slash" : "bolt") {
                    if model.isConnected || model.isBusy {
                        model.disconnect()
                    } else {
                        model.connect()
                    }
                }
                .disabled(model.activeProfile == nil && !model.isConnected)
            }
            ToolbarItem {
                Button("Connections…", systemImage: "gearshape") { showConnections = true }
                    .help("Edit connection profiles")
            }
            ToolbarItem {
                Button("Subscriptions", systemImage: "list.bullet.rectangle") { showSubscriptions.toggle() }
                    .help("Show and edit the topic subscriptions")
                    .disabled(!model.isConnected)
                    .popover(isPresented: $showSubscriptions) { SubscriptionsPopover() }
            }
            ToolbarItem {
                Button("Export", systemImage: "square.and.arrow.up") { exportTree() }
                    .help("Export the topic tree with the latest values as JSON")
                    .disabled(model.topicCount == 0)
            }
            ToolbarItem {
                Toggle("Pause", systemImage: "pause.fill", isOn: $model.paused)
                    .help("Pause incoming messages")
            }
            ToolbarItem {
                Button("Clear tree", systemImage: "trash") { model.clearTree() }
                    .help("Clear the local topic tree")
            }
        }
        .sheet(isPresented: $showConnections) { ConnectionsSheet() }
        .onChange(of: model.profiles) { _, _ in model.saveProfiles() }
        .task {
            if model.profiles.isEmpty { showConnections = true }
        }
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var color: Color {
        switch model.status {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .secondary
        case .failed: return .red
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(model.statusText)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(model.statusText)
            Spacer()
            Text("\(model.topicCount) topics · \(model.totalMessages) messages")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

// MARK: - Topic tree

struct TreePane: View {
    @Environment(AppModel.self) private var model
    let onConfigure: () -> Void

    private var emptyTitle: String {
        if !model.filter.isEmpty { return "No matches" }
        if model.isConnected && model.subscriptions.isEmpty { return "No subscriptions" }
        return model.isConnected ? "Waiting for messages…" : "No topics yet"
    }

    private var emptyText: String {
        if !model.filter.isEmpty { return "" }
        if model.isConnected && model.subscriptions.isEmpty {
            return "This connection has no subscriptions. Use the Subscriptions button in the toolbar and add a topic filter, for example #."
        }
        return model.isConnected
            ? "Connected, but no messages have arrived. Check the subscriptions (toolbar) and the access rights (ACL) of this user on the broker."
            : "Connect to a broker."
    }

    var body: some View {
        @Bindable var model = model
        let items = model.treeItems()

        List(items, children: \.children, selection: $model.selectedTopic) { item in
            TopicRow(node: item.node)
        }
        .listStyle(.sidebar)
        .overlay {
            if items.isEmpty {
                if model.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No connection configured", systemImage: "network")
                    } description: {
                        Text("Add your MQTT broker to get started.")
                    } actions: {
                        Button("Add connection…", action: onConfigure)
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView(emptyTitle, systemImage: "tray", description: Text(emptyText))
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !model.deniedSubscriptions.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("The broker denied the subscription to \(model.deniedSubscriptions.sorted().joined(separator: ", ")). Check the ACL of this user or change the subscriptions.")
                        .font(.caption)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.15))
            }
        }
    }
}

struct TopicRow: View {
    let node: TopicNode
    @State private var flash = false

    var body: some View {
        HStack(spacing: 6) {
            Text(node.name.isEmpty ? "(empty)" : node.name)
                .fontWeight(.medium)
                .lineLimit(1)
            if let m = node.lastMessage {
                if m.retain {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                }
                Text("= " + m.preview)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if node.descendantTopics > 0 {
                Text("\(node.topicCount) topics")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("\(node.messageCount + node.descendantMessages)")
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.accentColor.opacity(flash ? 0.35 : 0))
        )
        .onChange(of: node.messageCount) { _, _ in
            // flash the row when a new value arrives
            flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.easeOut(duration: 1.1)) { flash = false }
            }
        }
    }
}

// MARK: - Details

struct DetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let node = model.selectedNode {
            NodeDetail(node: node)
                .id(node.id)
        } else {
            ContentUnavailableView("Select a topic", systemImage: "list.bullet.indent")
        }
    }
}

enum DetailTab: String, CaseIterable, Identifiable {
    case value = "Value"
    case diff = "Changes"
    case chart = "Chart"
    case history = "History"
    var id: String { rawValue }
}

struct NodeDetail: View {
    let node: TopicNode
    @Environment(AppModel.self) private var model
    @State private var tab: DetailTab = .value
    @State private var format: PayloadFormat = .auto
    @State private var pickedID: UUID?
    @State private var confirmClear = false

    private var shown: MQTTMessage? {
        if let id = pickedID, let m = node.history.first(where: { $0.id == id }) { return m }
        return node.lastMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Picker("", selection: $tab) {
                ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case .value: valueTab
                case .diff: diffTab
                case .chart: chartTab
                case .history: historyTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .alert("Clear retained messages", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { model.clearRetained(under: node) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("An empty retained message will be published to \"\(node.id)\" and every topic below it.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(node.id.isEmpty ? "(empty)" : node.id)
                    .font(.headline)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer()
                Button("Copy topic", systemImage: "doc.on.doc") { copy(node.id) }
                    .labelStyle(.iconOnly).help("Copy topic")
                Button("Copy value", systemImage: "doc.on.clipboard") {
                    if let m = shown { copy(m.display(format)) }
                }
                .labelStyle(.iconOnly).help("Copy value")
                Button("Clear retained", systemImage: "pin.slash") { confirmClear = true }
                    .labelStyle(.iconOnly).help("Clear retained messages on the broker")
                    .disabled(!model.isConnected)
            }
            if let m = shown {
                HStack(spacing: 14) {
                    Label("QoS \(m.qos)", systemImage: "arrow.down.circle")
                    if m.retain { Label("retained", systemImage: "pin.fill").foregroundStyle(.orange) }
                    Label("\(m.payload.count) bytes", systemImage: "ruler")
                    Label(m.date.formatted(date: .omitted, time: .standard), systemImage: "clock")
                    Label("\(node.messageCount) messages", systemImage: "number")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var valueTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Format", selection: $format) {
                    ForEach(PayloadFormat.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 190)
                Spacer()
                if pickedID != nil {
                    Button("Latest") { pickedID = nil }
                }
            }
            .padding([.horizontal, .top], 8)

            if let m = shown {
                ScrollView {
                    Text(m.display(format))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            } else {
                Text("This topic has no value.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var diffTab: some View {
        Group {
            if let m = shown,
               let idx = node.history.firstIndex(where: { $0.id == m.id }), idx > 0 {
                DiffView(old: node.history[idx - 1].display(.auto), new: m.display(.auto))
            } else {
                Text("There is no earlier value to compare with.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chartTab: some View {
        let points = node.history.compactMap { m in
            m.numericValue.map { ChartPoint(date: m.date, value: $0) }
        }
        return Group {
            if points.count >= 2 {
                Chart(points) { p in
                    LineMark(x: .value("Time", p.date), y: .value("Value", p.value))
                    PointMark(x: .value("Time", p.date), y: .value("Value", p.value))
                        .symbolSize(18)
                }
                .padding(12)
            } else {
                Text("A chart needs at least two numeric values.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var historyTab: some View {
        List(Array(node.history.reversed()), selection: $pickedID) { m in
            HStack {
                Text(m.date.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
                Text(m.preview).lineLimit(1)
                Spacer()
                if m.retain { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
            }
            .tag(m.id)
        }
        .onChange(of: pickedID) { _, new in
            if new != nil { tab = .value }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct ChartPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

// MARK: - Diff

struct DiffLine: Identifiable {
    enum Kind { case same, added, removed }
    let id = UUID()
    let kind: Kind
    let text: String
}

func diffLines(old: String, new: String) -> [DiffLine] {
    let a = old.components(separatedBy: "\n")
    let b = new.components(separatedBy: "\n")
    var removed = Set<Int>()
    var inserted = Set<Int>()
    for change in b.difference(from: a) {
        switch change {
        case .remove(let offset, _, _): removed.insert(offset)
        case .insert(let offset, _, _): inserted.insert(offset)
        }
    }
    var result: [DiffLine] = []
    var i = 0, j = 0
    while i < a.count || j < b.count {
        if i < a.count, removed.contains(i) {
            result.append(DiffLine(kind: .removed, text: a[i])); i += 1
        } else if j < b.count, inserted.contains(j) {
            result.append(DiffLine(kind: .added, text: b[j])); j += 1
        } else {
            if j < b.count { result.append(DiffLine(kind: .same, text: b[j])) }
            i += 1; j += 1
        }
    }
    return result
}

struct DiffView: View {
    let lines: [DiffLine]

    init(old: String, new: String) {
        lines = diffLines(old: old, new: new)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { l in
                    Text(prefix(l.kind) + l.text)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .background(color(l.kind))
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 6)
        }
    }

    private func prefix(_ k: DiffLine.Kind) -> String {
        switch k {
        case .same: return "  "
        case .added: return "+ "
        case .removed: return "− "
        }
    }

    private func color(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .same: return .clear
        case .added: return .green.opacity(0.22)
        case .removed: return .red.opacity(0.22)
        }
    }
}

// MARK: - Publish

struct PublishPane: View {
    @Environment(AppModel.self) private var model
    @State private var topic = ""
    @State private var payload = ""
    @State private var qos = 0
    @State private var retain = false
    @State private var feedback: String?
    @State private var feedbackIsError = false

    var body: some View {
        VStack(spacing: 0) {
            // The form scrolls when the pane is small ...
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Publish").font(.headline)
                    HStack {
                        TextField("Topic", text: $topic)
                            .textFieldStyle(.roundedBorder)
                        Picker("QoS", selection: $qos) {
                            ForEach(0..<3) { Text("QoS \($0)").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        Toggle("Retain", isOn: $retain)
                    }
                    TextEditor(text: $payload)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 120)
                        .border(.separator)
                }
                .padding(10)
            }

            // ... while the buttons are pinned and always visible.
            Divider()
            HStack {
                Button("Format JSON") { formatJSON() }
                Menu("Recent", systemImage: "clock.arrow.circlepath") {
                    ForEach(model.recentPublishes) { item in
                        Button("\(item.topic)  ·  \(String(item.payload.prefix(40)))") {
                            topic = item.topic
                            payload = item.payload
                            qos = item.qos
                            retain = item.retain
                        }
                    }
                }
                .fixedSize()
                .disabled(model.recentPublishes.isEmpty)
                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(feedbackIsError ? Color.red : Color.green)
                }
                Spacer()
                Button("Publish") { send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isConnected || topic.isEmpty)
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.selectedTopic) { _, new in
            if let new { topic = new }
        }
    }

    private func send() {
        if let err = model.publish(topic: topic, payload: payload, qos: qos, retain: retain) {
            feedback = err
            feedbackIsError = true
        } else {
            feedback = "Published"
            feedbackIsError = false
        }
    }

    private func formatJSON() {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: out, encoding: .utf8) else {
            feedback = "Invalid JSON"
            feedbackIsError = true
            return
        }
        payload = s
        feedback = nil
    }
}

// MARK: - Connection profiles

struct ConnectionsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var showDiscovery = false
    @State private var confirmRemove = false

    private var selectedName: String {
        model.profiles.first { $0.id == selection }?.displayName ?? ""
    }

    /// A binding that stays valid even if the profile is removed while the form is still on screen.
    private func binding(for id: UUID) -> Binding<ConnectionProfile> {
        Binding(
            get: { model.profiles.first { $0.id == id } ?? ConnectionProfile() },
            set: { new in
                if let i = model.profiles.firstIndex(where: { $0.id == id }) { model.profiles[i] = new }
            }
        )
    }

    private var canConnect: Bool {
        guard let p = model.profiles.first(where: { $0.id == selection }) else { return false }
        return !p.hasErrors
    }

    private func connectSelected() {
        guard let id = selection else { return }
        model.activeProfileID = id
        dismiss()
        model.connect()
    }

    private func add(_ profile: ConnectionProfile) {
        model.profiles.append(profile)
        selection = profile.id
        if model.activeProfileID == nil { model.activeProfileID = profile.id }
    }

    private func removeSelected() {
        guard let id = selection,
              let profile = model.profiles.first(where: { $0.id == id }) else { return }
        if model.activeProfileID == id { model.disconnect() }
        profile.removeStoredSecrets()
        model.profiles.removeAll { $0.id == id }
        selection = model.profiles.first?.id
        if model.activeProfileID == id { model.activeProfileID = selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(model.profiles) { p in
                            Text(p.displayName).tag(p.id)
                        }
                    }
                    Divider()
                    HStack {
                        Button("Add", systemImage: "plus") { add(ConnectionProfile()) }
                        Button("Remove", systemImage: "minus") { confirmRemove = true }
                            .disabled(selection == nil)
                        Spacer()
                        Button("Find brokers on the network", systemImage: "dot.radiowaves.left.and.right") {
                            showDiscovery = true
                        }
                        .help("Find MQTT brokers on the local network")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .padding(8)
                }
                .frame(minWidth: 170, idealWidth: 190, maxWidth: 240)

                Group {
                    if let id = selection, model.profiles.contains(where: { $0.id == id }) {
                        ProfileForm(profile: binding(for: id))
                            .id(id)
                    } else {
                        ContentUnavailableView {
                            Label(model.profiles.isEmpty ? "No connections yet" : "No connection selected",
                                  systemImage: "network")
                        } description: {
                            Text("Add a connection, or let the app look for MQTT brokers on your network.")
                        } actions: {
                            Button("Add connection") { add(ConnectionProfile()) }
                                .buttonStyle(.borderedProminent)
                            Button("Find brokers on the network") { showDiscovery = true }
                        }
                    }
                }
                .frame(minWidth: 460)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connectSelected() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnect)
                    .help(canConnect ? "Save and connect with this profile" : "Fix the errors in the profile first")
            }
            .padding(12)
        }
        .frame(width: 780, height: 700)
        .onAppear { selection = model.activeProfileID ?? model.profiles.first?.id }
        .confirmationDialog("Remove \u{201C}\(selectedName)\u{201D}?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { removeSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The profile and its stored passwords and certificates will be deleted.")
        }
        .sheet(isPresented: $showDiscovery) {
            DiscoverySheet { broker in
                var p = ConnectionProfile()
                p.name = broker.name == broker.host ? "MQTT @ \(broker.host)" : broker.name
                p.host = broker.host
                p.port = broker.port
                p.useTLS = broker.useTLS
                add(p)
            }
        }
    }
}

// MARK: - Broker discovery

struct DiscoverySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var discovery = BrokerDiscovery()
    @State private var added: Set<String> = []
    let onAdd: (DiscoveredBroker) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MQTT brokers on the local network").font(.headline)
                Spacer()
                if discovery.isScanning {
                    ProgressView(value: discovery.progress).frame(width: 120)
                }
                Button("Scan again") { discovery.start() }
                    .disabled(discovery.isScanning)
            }
            .padding(12)
            Divider()

            List(discovery.results) { b in
                HStack(spacing: 10) {
                    Image(systemName: b.confirmed ? "checkmark.circle.fill" : "questionmark.circle")
                        .foregroundStyle(b.confirmed ? Color.green : Color.orange)
                        .help(b.confirmed ? "Confirmed MQTT broker" : "The port is open, but no MQTT reply was received")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.name).fontWeight(.medium)
                        Text("\(b.host):\(b.port)" + (b.useTLS ? " · TLS" : ""))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(b.source.rawValue + (b.confirmed ? "" : " · unconfirmed"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if b.useTLS {
                            Text("Connecting by IP address? Set a Server name under Advanced, or verify the certificate only.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(added.contains(b.id) ? "Added" : "Add") {
                        onAdd(b)
                        added.insert(b.id)
                    }
                    .disabled(added.contains(b.id))
                }
            }
            .overlay {
                if discovery.results.isEmpty {
                    if discovery.isScanning {
                        ProgressView("Searching…")
                    } else {
                        ContentUnavailableView("Nothing found", systemImage: "network.slash",
                                               description: Text(discovery.message ?? ""))
                    }
                }
            }

            Divider()
            HStack {
                if let msg = discovery.message, !discovery.results.isEmpty {
                    Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 600, height: 460)
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }
}

// MARK: - File drop zone

struct FileDropZone: View {
    let icon: String
    let title: String
    let subtitle: String
    let types: [UTType]
    let onPick: (URL) -> Void

    @State private var targeted = false
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title2)
            Text(title).fontWeight(.medium).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 78)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
        )
        .background(targeted ? Color.accentColor.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { showImporter = true }
        .dropDestination(for: URL.self, action: { urls, _ in
            guard let url = urls.first else { return false }
            onPick(url)
            return true
        }, isTargeted: { targeted = $0 })
        .fileImporter(isPresented: $showImporter, allowedContentTypes: types) { result in
            if case .success(let url) = result { onPick(url) }
        }
    }
}

private func readFile(_ url: URL) -> Data? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    return try? Data(contentsOf: url)
}

// MARK: - Profile editor

struct ProfileForm: View {
    @Binding var profile: ConnectionProfile

    @State private var newFilter = ""
    @State private var p12Password = ""
    @State private var p12Lines: [String] = []
    @State private var p12ChainCount = 0
    @State private var p12Error: String?
    @State private var caLines: [String] = []
    @State private var caError: String?
    @State private var advancedExpanded = false
    @State private var tester = ConnectionTester()
    @State private var pendingTrust: ConnectionTester.UntrustedRoot?
    @FocusState private var hostFocused: Bool
    @FocusState private var passwordFocused: Bool

    var body: some View {
        Form {
            let issues = profile.issues
            if !issues.isEmpty {
                Section {
                    ForEach(issues) { issue in
                        Label(issue.message,
                              systemImage: issue.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.isError ? Color.red : Color.orange)
                            .font(.callout)
                    }
                }
            }

            connectionSection
            authenticationSection
            subscriptionsSection
            if profile.useTLS {
                tlsSection
                caSection
                clientCertSection
            }
            sessionSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .onAppear {
            p12Password = Keychain.get(profile.p12PasswordKey)
            advancedExpanded = !profile.serverName.isEmpty || !profile.alpn.isEmpty
            refreshP12()
            refreshCA()
        }
        .onChange(of: p12Password) { _, new in
            Keychain.set(new, for: profile.p12PasswordKey)
            refreshP12()
        }
        .onChange(of: profile.useTLS) { _, tls in
            if tls && profile.port == 1883 { profile.port = 8883 }
            if !tls && profile.port == 8883 { profile.port = 1883 }
        }
        .alert("Trust this certificate?",
               isPresented: Binding(get: { pendingTrust != nil }, set: { if !$0 { pendingTrust = nil } }),
               presenting: pendingTrust) { root in
            Button("Trust") { trustServerCertificate(root) }
            Button("Cancel", role: .cancel) {}
        } message: { root in
            Text("\(root.subject)\n\nSHA-256:\n\(root.fingerprint)\n\nOnly continue if this fingerprint matches the CA of your broker.")
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section {
            TextField("Name", text: $profile.name, prompt: Text("e.g. Home broker"))
            Picker("Protocol", selection: $profile.useTLS) {
                Text("mqtt:// (plain TCP)").tag(false)
                Text("mqtts:// (TLS)").tag(true)
            }
            TextField("Host", text: $profile.host, prompt: Text("broker.example.com or 192.168.1.10"))
                .focused($hostFocused)
                .onSubmit(normalizeHost)
                .onChange(of: hostFocused) { _, focused in
                    if !focused { normalizeHost() }
                }
            TextField("Port", value: $profile.port, format: .number.grouping(.never))
        } header: {
            Text("Connection")
        } footer: {
            Text(profile.urlPreview).font(.caption.monospaced())
        }
    }

    /// Accepts pasted addresses such as `mqtts://user@host:8883` or `host:1883`.
    private func normalizeHost() {
        let text = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != profile.host { profile.host = text }

        if text.contains("://") {
            guard let comps = URLComponents(string: text), let host = comps.host, !host.isEmpty else { return }
            switch comps.scheme?.lowercased() {
            case "mqtts", "ssl", "tls": profile.useTLS = true
            case "mqtt", "tcp": profile.useTLS = false
            default: break
            }
            if let port = comps.port { profile.port = port }
            if let user = comps.user, profile.username.isEmpty { profile.username = user }
            profile.host = host
            return
        }

        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = Int(parts[1]), !parts[0].isEmpty {
            profile.host = String(parts[0])
            profile.port = port
        }
    }

    // MARK: Authentication

    private var authenticationSection: some View {
        Section {
            TextField("User name", text: $profile.username, prompt: Text("optional"))
            SecureField("Password", text: Binding(
                get: { Keychain.get(profile.id.uuidString) },
                set: { Keychain.set($0, for: profile.id.uuidString) }
            ), prompt: Text("optional"))
        } header: {
            Text("Authentication")
        } footer: {
            Text("The password is stored in the macOS Keychain.")
        }
    }

    // MARK: Subscriptions

    private var subscriptionsSection: some View {
        Section {
            if profile.subscriptionFilters.isEmpty {
                Label("No subscriptions yet", systemImage: "tray")
                    .foregroundStyle(.secondary)
            }
            ForEach(profile.subscriptionFilters.indices, id: \.self) { i in
                let filter = i < profile.subscriptionFilters.count ? profile.subscriptionFilters[i] : ""
                HStack {
                    TextField("Topic filter", text: filterBinding(i))
                        .labelsHidden()
                        .font(.body.monospaced())
                    if !ConnectionProfile.isValidFilter(filter) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .help("This is not a valid MQTT topic filter")
                    }
                    Button("Remove", systemImage: "minus.circle") { removeFilter(at: i) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Add topic filter", text: $newFilter,
                          prompt: Text("e.g. home/# or sensors/+/temperature"))
                    .onSubmit(addTyped)
                Button("Add", action: addTyped)
                    .disabled(newFilter.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu("Presets", systemImage: "wand.and.stars") {
                    Button("Everything  (#)") { addFilter("#") }
                    Button("Broker statistics  ($SYS/#)") { addFilter("$SYS/#") }
                }
                .fixedSize()
            }
            Picker("Subscription QoS", selection: $profile.subscriptionQoS) {
                Text("0 – at most once").tag(0)
                Text("1 – at least once").tag(1)
                Text("2 – exactly once").tag(2)
            }
        } header: {
            Text("Subscriptions")
        } footer: {
            Text("The topics the app subscribes to after connecting. # matches everything except $SYS topics, + matches exactly one level. Only topics this user may read (see the broker ACL) deliver messages. A message arrives with the lower of the QoS it was published with and the QoS chosen here.")
        }
    }

    private func filterBinding(_ i: Int) -> Binding<String> {
        Binding(
            get: { i < profile.subscriptionFilters.count ? profile.subscriptionFilters[i] : "" },
            set: { if i < profile.subscriptionFilters.count { profile.subscriptionFilters[i] = $0 } }
        )
    }

    private func addFilter(_ raw: String) {
        let filter = raw.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty, !profile.subscriptionFilters.contains(filter) else { return }
        profile.subscriptionFilters.append(filter)
    }

    private func addTyped() {
        addFilter(newFilter)
        newFilter = ""
    }

    private func removeFilter(at i: Int) {
        if i < profile.subscriptionFilters.count { profile.subscriptionFilters.remove(at: i) }
    }

    // MARK: TLS

    private var verificationNote: String {
        switch profile.serverVerification {
        case .full:
            return "The server certificate must be valid and issued for the host name (or server name) of this connection."
        case .caOnly:
            return "The certificate chain is verified, but the host name is not. Useful when you connect by IP address."
        case .none:
            return "Nothing is verified. Use this for testing only."
        }
    }

    private var tlsSection: some View {
        Section {
            Picker("Server verification", selection: $profile.serverVerification) {
                ForEach(ServerVerification.allCases) { Text($0.title).tag($0) }
            }
            Picker("Minimum TLS version", selection: $profile.minTLS) {
                ForEach(TLSVersion.allCases) { Text($0.rawValue).tag($0) }
            }
            DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                TextField("Server name (SNI / host name to verify)", text: $profile.serverName,
                          prompt: Text("defaults to the host"))
                TextField("ALPN protocol", text: $profile.alpn, prompt: Text("optional, e.g. mqtt"))
            }
        } header: {
            Text("TLS")
        } footer: {
            Text(verificationNote)
        }
    }

    private var caSection: some View {
        Section {
            FileDropZone(
                icon: profile.hasCustomCA ? "checkmark.seal.fill" : "doc.badge.plus",
                title: profile.hasCustomCA ? profile.caFileName : "Drop a CA certificate here",
                subtitle: profile.hasCustomCA ? "Click or drop another file to replace it"
                                              : "PEM, CRT, CER or DER — or click to browse",
                types: [.x509Certificate, .data],
                onPick: importCA
            )
            if let caError {
                Label(caError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            } else {
                ForEach(caLines, id: \.self) { line in
                    Label(line, systemImage: "checkmark.seal").font(.caption)
                }
            }
            if profile.hasCustomCA || p12ChainCount > 0 {
                Toggle("Trust only imported CAs (ignore system CAs)", isOn: $profile.trustOnlyImportedCAs)
            }
            if profile.hasCustomCA {
                Button("Remove CA certificate", role: .destructive) { removeCA() }
            }
        } header: {
            Text("CA certificate (optional)")
        } footer: {
            Text("CA certificates found in the client P12 file are used automatically as well. They are not used while server verification is off.")
        }
    }

    private var clientCertSection: some View {
        Section {
            FileDropZone(
                icon: profile.hasClientIdentity ? "key.fill" : "square.and.arrow.down",
                title: profile.hasClientIdentity ? profile.p12FileName : "Drop a .p12 file here",
                subtitle: profile.hasClientIdentity ? "Click or drop another file to replace it"
                                                    : "Client key, certificate and CA — or click to browse",
                types: [UTType.pkcs12, UTType(filenameExtension: "pfx")].compactMap { $0 },
                onPick: importP12
            )
            if profile.hasClientIdentity {
                SecureField("P12 password", text: $p12Password)
                    .focused($passwordFocused)
                if let p12Error {
                    Label(p12Error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                } else {
                    ForEach(p12Lines, id: \.self) { line in
                        Label(line, systemImage: "checkmark.seal").font(.caption)
                    }
                }
                Button("Remove client certificate", role: .destructive) { removeP12() }
            }
        } header: {
            Text("Client certificate (mutual TLS)")
        } footer: {
            Text("The P12 file and its password are stored in the macOS Keychain.")
        }
    }

    // MARK: Session

    private var sessionSection: some View {
        Section {
            LabeledContent("Client ID") {
                HStack {
                    TextField("Client ID", text: $profile.clientID)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                    Button("Generate", systemImage: "arrow.triangle.2.circlepath") {
                        profile.clientID = ConnectionProfile.randomClientID()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Generate a random client ID")
                }
            }
            Stepper(profile.keepAlive == 0 ? "Keep-alive: off" : "Keep-alive: \(profile.keepAlive) s",
                    value: $profile.keepAlive, in: 0...600, step: 10)
            Toggle("Clean session", isOn: $profile.cleanSession)
        } header: {
            Text("Session")
        } footer: {
            Text("Clean session off: the broker remembers the subscriptions and queues QoS 1 and 2 messages while the app is offline. This needs a fixed client ID, and every client must use its own.")
        }
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        Section {
            HStack {
                Button("Test connection", systemImage: "checkmark.shield") {
                    let snapshot = profile
                    Task { await tester.run(profile: snapshot) }
                }
                .disabled(tester.isRunning || profile.host.trimmingCharacters(in: .whitespaces).isEmpty)
                if tester.isRunning { ProgressView().controlSize(.small) }
            }
            ForEach(tester.lines) { line in
                Label {
                    Text(line.text).textSelection(.enabled)
                } icon: {
                    Image(systemName: symbol(line.kind)).foregroundStyle(color(line.kind))
                }
                .font(.callout)
            }
            if let root = tester.untrustedRoot {
                Button("Trust \u{201C}\(root.subject)\u{201D}…", systemImage: "checkmark.shield") {
                    pendingTrust = root
                }
            }
            ForEach(tester.suggestedNames, id: \.self) { name in
                Button("Use \u{201C}\(name)\u{201D} as server name", systemImage: "textformat") {
                    profile.serverName = name
                    advancedExpanded = true
                    let snapshot = profile
                    Task { await tester.run(profile: snapshot) }
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Connects with the settings above and shows each step: client certificate, TLS handshake, server certificate chain and the broker's reply.")
        }
    }

    private func symbol(_ k: ConnectionTester.Kind) -> String {
        switch k {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        case .info: return "info.circle"
        }
    }

    private func color(_ k: ConnectionTester.Kind) -> Color {
        switch k {
        case .ok: return .green
        case .warning: return .orange
        case .failure: return .red
        case .info: return .secondary
        }
    }

    // MARK: P12

    private func importP12(_ url: URL) {
        guard let data = readFile(url) else {
            p12Error = "The file cannot be read."
            return
        }
        Keychain.setData(data, for: profile.p12DataKey)
        profile.p12FileName = url.lastPathComponent
        profile.hasClientIdentity = true
        refreshP12()
        // The file is usually password protected, so jump to the password field.
        DispatchQueue.main.async { passwordFocused = true }
    }

    private func removeP12() {
        Keychain.setData(nil, for: profile.p12DataKey)
        Keychain.set("", for: profile.p12PasswordKey)
        profile.hasClientIdentity = false
        profile.p12FileName = ""
        p12Password = ""
        p12Lines = []
        p12ChainCount = 0
        p12Error = nil
    }

    private func refreshP12() {
        guard profile.hasClientIdentity, let data = Keychain.getData(profile.p12DataKey) else {
            p12Lines = []
            p12ChainCount = 0
            p12Error = nil
            return
        }
        do {
            let b = try P12Bundle.load(data: data, password: p12Password)
            var lines = ["Client certificate: \(b.clientSubject)"]
            if b.caSubjects.isEmpty {
                lines.append("No CA / intermediate certificates in the file")
            } else {
                lines += b.caSubjects.map { "Chain: \($0)" }
            }
            p12Lines = lines
            p12ChainCount = b.caSubjects.count
            p12Error = nil
        } catch {
            p12Lines = []
            p12ChainCount = 0
            if let e = error as? P12Bundle.LoadError, e.passwordProblem, p12Password.isEmpty {
                p12Error = "The file is password protected. Enter the P12 password."
            } else {
                p12Error = error.localizedDescription
            }
        }
    }

    // MARK: CA

    /// Adds a certificate seen during the handshake to the trusted CA certificates of this profile.
    private func trustServerCertificate(_ root: ConnectionTester.UntrustedRoot) {
        guard let cert = SecCertificateCreateWithData(nil, root.der as CFData) else { return }
        var certs = profile.hasCustomCA
            ? CertificateFile.parse(Keychain.getData(profile.caDataKey) ?? Data())
            : []
        if !certs.contains(where: { CFEqual($0, cert) }) { certs.append(cert) }
        Keychain.setData(CertificateFile.pem(certs), for: profile.caDataKey)
        profile.hasCustomCA = true
        if profile.caFileName.isEmpty { profile.caFileName = "Trusted from server" }
        refreshCA()
        let snapshot = profile
        Task { await tester.run(profile: snapshot) }
    }

    private func importCA(_ url: URL) {
        guard let data = readFile(url) else {
            caError = "The file cannot be read."
            return
        }
        Keychain.setData(data, for: profile.caDataKey)
        profile.caFileName = url.lastPathComponent
        profile.hasCustomCA = true
        refreshCA()
    }

    private func removeCA() {
        Keychain.setData(nil, for: profile.caDataKey)
        profile.hasCustomCA = false
        profile.caFileName = ""
        caLines = []
        caError = nil
    }

    private func refreshCA() {
        guard profile.hasCustomCA, let data = Keychain.getData(profile.caDataKey) else {
            caLines = []
            caError = nil
            return
        }
        let certs = CertificateFile.parse(data)
        if certs.isEmpty {
            caLines = []
            caError = "No certificate found in this file. Use a PEM, CRT, CER or DER file."
        } else {
            caLines = certs.map { "CA: \(CertificateFile.subject($0))" }
            caError = nil
        }
    }
}

// MARK: - Subscriptions

struct SubscriptionsPopover: View {
    @Environment(AppModel.self) private var model
    @State private var newFilter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Subscriptions").font(.headline)

            if model.subscriptions.isEmpty {
                Text("No subscriptions yet. Add a topic filter below, or start with a preset.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Everything (#)") { model.addSubscription("#") }
                    Button("Broker statistics ($SYS/#)") { model.addSubscription("$SYS/#") }
                }
            }
            ForEach(model.subscriptions, id: \.self) { filter in
                let denied = model.deniedSubscriptions.contains(filter)
                HStack {
                    Image(systemName: denied ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(denied ? Color.red : Color.green)
                    Text(filter).font(.body.monospaced())
                    if denied {
                        Text("denied by the broker").font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { model.removeSubscription(filter) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }

            Divider()
            HStack {
                TextField("Topic filter, e.g. home/#", text: $newFilter)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newFilter.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Changes take effect immediately and are saved in the connection profile.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 380)
    }

    private func add() {
        model.addSubscription(newFilter)
        newFilter = ""
    }
}

// MARK: - Detail column (details on top, publish pane below, draggable divider)

struct DetailColumn: View {
    @AppStorage("publishPaneHeight") private var storedHeight = 250.0
    @State private var dragStartHeight: Double?

    var body: some View {
        GeometryReader { geo in
            let limit = max(180.0, Double(geo.size.height) - 140.0)
            let height = min(max(storedHeight, 180.0), limit)

            VStack(spacing: 0) {
                DetailPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                resizeHandle(current: height, limit: limit)
                PublishPane()
                    .frame(height: CGFloat(height))
                    .clipped()
            }
        }
    }

    private func resizeHandle(current: Double, limit: Double) -> some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .frame(height: 8)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartHeight == nil { dragStartHeight = current }
                    let proposed = (dragStartHeight ?? current) - Double(value.translation.height)
                    storedHeight = min(max(proposed, 180.0), limit)
                }
                .onEnded { _ in dragStartHeight = nil }
        )
    }
}

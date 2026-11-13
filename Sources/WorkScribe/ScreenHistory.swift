import AppKit
import SwiftUI
import WorkScribeCore

/// A day of screen reading, by application. Opened from Settings, and by `workscribe://screen/<day>?t=` links.
@MainActor enum ScreenHistoryWindow {
    private static var window: NSWindow?
    private static let request = ScreenHistoryRequest()

    static func open(model: AppModel, day: String? = nil, seconds: Double? = nil) {
        request.day = day ?? ScreenDayStore.day(Date()).id
        request.seconds = seconds
        request.token = UUID()
        if window == nil {
            let hosting = NSHostingController(rootView: ScreenHistoryView(model: model, request: request))
            let made = NSWindow(contentViewController: hosting)
            made.title = "Screen history"
            made.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            made.setContentSize(NSSize(width: 820, height: 600))
            made.isReleasedWhenClosed = false
            made.center()
            window = made
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor final class ScreenHistoryRequest: ObservableObject {
    @Published var day = ScreenDayStore.day(Date()).id
    @Published var seconds: Double?
    @Published var token = UUID()
}

struct ScreenHistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var request: ScreenHistoryRequest
    @State private var loaded: ScreenDay?
    @State private var days: [String] = []
    /// A bundle identifier (or app name when there is none) to show alone.
    @State private var app: String?
    @State private var expanded: Set<String> = []

    private var today: String { ScreenDayStore.day(Date()).id }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                apps.frame(width: 260)
                Divider()
                moments
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .task(id: request.token) { await reload() }
        .onChange(of: model.screenTodayMoments) { if request.day == today { Task { await reload() } } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $request.day) {
                ForEach(days.contains(request.day) ? days : [request.day] + days, id: \.self) { Text(Self.title($0, today: today)).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 220)
            .onChange(of: request.day) { app = nil; request.seconds = nil; Task { await reload() } }
            Text(summary).foregroundStyle(.secondary).font(.callout)
            Spacer()
            Text(model.screenMode == .allDay ? model.screenState.label : "All-day screen reading is off")
                .foregroundStyle(.secondary).font(.callout)
            Menu {
                Button("Delete this day’s screen history", role: .destructive) { Task { await model.deleteScreenDay(request.day); await reload() } }
                Button("Delete all screen history", role: .destructive) { Task { await model.deleteAllScreenHistory(); await reload() } }
            } label: { Image(systemName: "trash") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Delete screen history")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var summary: String {
        guard let loaded, !loaded.isEmpty else { return "Nothing read" }
        let total = loaded.usage.reduce(0) { $0 + $1.seconds }
        let apps = Set(loaded.usage.map { $0.bundleID ?? $0.app }).count
        return "\(Self.duration(total)) in \(apps) app\(apps == 1 ? "" : "s") · \(loaded.moments.count) stretch\(loaded.moments.count == 1 ? "" : "es") of text"
    }

    // MARK: By application

    private var apps: some View {
        let totals = loaded?.byApp() ?? []
        let longest = max(totals.first?.seconds ?? 1, 1)
        return List {
            Section("Applications") {
                row(label: "All applications", detail: Self.duration(totals.reduce(0) { $0 + $1.seconds }), fraction: nil, selected: app == nil) { app = nil }
                ForEach(totals, id: \.app) { total in
                    let key = total.bundleID ?? total.app
                    row(label: total.app, detail: Self.duration(total.seconds) + (total.category.map { " · \($0)" } ?? ""),
                        fraction: total.seconds / longest, selected: app == key) { app = app == key ? nil : key }
                        .contextMenu {
                            if let bundle = total.bundleID {
                                Button("Never read \(total.app)") { model.setScreenReading(false, for: bundle) }
                                Button("Forget what was read from \(total.app) this day", role: .destructive) {
                                    Task { await model.forgetScreenApp(bundle, day: request.day); await reload() }
                                }
                            }
                        }
                }
            }
            let denied = model.screenDenyList
            if !denied.isEmpty {
                Section("Never read") {
                    ForEach(denied, id: \.self) { bundle in
                        HStack {
                            Text(Self.appName(bundle)).lineLimit(1)
                            Spacer()
                            Button("Allow") { model.setScreenReading(true, for: bundle) }.buttonStyle(.link)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(label: String, detail: String, fraction: Double?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(label).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                    Spacer()
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let fraction {
                    GeometryReader { space in
                        Capsule().fill(Color.accentColor.opacity(selected ? 0.9 : 0.45))
                            .frame(width: max(3, space.size.width * fraction), height: 3)
                    }.frame(height: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: What was read

    private var shown: [ScreenMoment] {
        guard let loaded else { return [] }
        return app.map { loaded.moments(app: $0) } ?? loaded.moments
    }

    private var moments: some View {
        ScrollViewReader { proxy in
            List {
                if shown.isEmpty {
                    Text(loaded?.isEmpty ?? true ? "Nothing was read on this day." : "No text was kept from this application.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { moment in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Self.clock(moment.start) + "–" + Self.clock(moment.end)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(moment.context ?? "A window").font(.callout.weight(.medium)).lineLimit(1)
                            Spacer()
                            if moment.source == "ocr" { Text("read from a picture").font(.caption2).foregroundStyle(.tertiary) }
                        }
                        if let url = moment.url, !url.isEmpty {
                            Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                        if !moment.text.isEmpty {
                            Text(moment.text).font(.callout).lineLimit(expanded.contains(moment.id) ? nil : 4).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("No readable text; kept so it can be found by what it looked like.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .onTapGesture { if !expanded.insert(moment.id).inserted { expanded.remove(moment.id) } }
                    .id(moment.id)
                    .listRowBackground(isFocused(moment) ? Color.accentColor.opacity(0.12) : Color.clear)
                }
            }
            .listStyle(.plain)
            .onChange(of: loaded?.day) { scroll(proxy) }
            .onChange(of: request.token) { scroll(proxy) }
        }
    }

    private func isFocused(_ moment: ScreenMoment) -> Bool {
        guard let seconds = request.seconds else { return false }
        return seconds >= moment.start - 0.5 && seconds <= moment.end + 0.5
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let seconds = request.seconds,
              let target = shown.first(where: isFocused) ?? shown.last(where: { $0.start <= seconds }) else { return }
        expanded.insert(target.id)
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(target.id, anchor: .top) } }
    }

    private func reload() async {
        let store = model.screenDays, day = request.day
        let result = await Task.detached(priority: .userInitiated) { (store.days(), store.load(day)) }.value
        days = result.0
        loaded = result.1
    }

    // MARK: Words

    static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d", value / 3600 % 24, value / 60 % 60)
    }
    static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "under a minute" }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
    static func title(_ day: String, today: String) -> String {
        if day == today { return "Today" }
        let parser = DateFormatter(); parser.dateFormat = "yyyy-MM-dd"; parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: day) else { return day }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }
    static func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }
}

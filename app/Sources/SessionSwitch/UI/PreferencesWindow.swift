import AppKit
import ServiceManagement
import SwiftUI

/// Mono Glass Preferences window: Injection behavior, Permissions status,
/// Launch at Login, and Presets management. A plain SwiftUI `View` (not a
/// `NSViewController`) -- `StatusItemController` hosts it in an
/// `NSWindow`/`NSHostingView` (see `showPreferences()`), forced to
/// `.darkAqua` since the app has no light-mode treatment.
struct PreferencesWindow: View {
    let presetStore: PresetStore

    /// Bound directly to the same `UserDefaults` key `Injector` reads at
    /// enqueue time (`Injector.queueWhenBusyDefaultsKey`); `@AppStorage`'s
    /// default store is `.standard`, matching the real app's
    /// `Injector(store:)` call (which also defaults to `.standard`) -- so
    /// toggling here takes effect on the very next injection request.
    @AppStorage(Injector.queueWhenBusyDefaultsKey) private var queueWhenBusy: Bool = true

    @State private var presets: [Preset] = []
    @State private var launchAtLoginNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                injectionSection
                Divider().overlay(Color(nsColor: Theme.dim).opacity(0.3))
                permissionsSection
                Divider().overlay(Color(nsColor: Theme.dim).opacity(0.3))
                launchAtLoginSection
                Divider().overlay(Color(nsColor: Theme.dim).opacity(0.3))
                presetsSection
            }
            .padding(24)
        }
        .frame(width: 480, height: 560)
        .background(Color.black)
        .foregroundColor(Color(nsColor: Theme.ink))
        .onAppear { presets = presetStore.presets }
    }

    // MARK: - Injection

    private var injectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Injection")
            Toggle("Queue changes while session is busy", isOn: $queueWhenBusy)
                .toggleStyle(.switch)
            Text(
                queueWhenBusy
                    ? "A model/effort change waits until the session goes idle, then applies automatically (FR-8 default)."
                    : "Changes apply immediately, even mid-response -- use with care."
            )
            .font(.system(size: 11))
            .foregroundColor(Color(nsColor: Theme.dim))
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Permissions")
            PermissionRow(name: "Terminal", bundleID: Permissions.terminalBundleID)
            PermissionRow(name: "iTerm2", bundleID: Permissions.iTerm2BundleID)
            Button("Open System Settings…") {
                openAutomationSettings()
            }
            .font(.system(size: 12))
        }
    }

    private func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Launch at Login

    private var launchAtLoginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Launch at Login")
            Toggle("Launch SessionSwitch at login", isOn: launchAtLoginBinding)
                .toggleStyle(.switch)
            if let launchAtLoginNote {
                Text(launchAtLoginNote)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: Theme.amber))
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enable in
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    // Unbundled SwiftPM binaries have been observed (live,
                    // on this machine) to let `register()` return without
                    // throwing yet leave `status` at `.notFound` -- i.e. a
                    // silent no-op, not just a thrown error. Check the
                    // *actual* resulting status rather than trusting the
                    // absence of a thrown error, so this case still shows
                    // the same note `unregister()`'s thrown-error path does.
                    let didApply = SMAppService.mainApp.status == (enable ? .enabled : .notRegistered)
                    launchAtLoginNote = didApply ? nil : "Launch at Login requires a proper .app bundle (unavailable in this build)"
                } catch {
                    // SPM/unbundled debug builds have no `.app` bundle for
                    // launchd to register, per the brief's explicit
                    // guidance: surface this rather than crash or silently
                    // no-op.
                    launchAtLoginNote = "Launch at Login requires a proper .app bundle (unavailable in this build): \(error.localizedDescription)"
                }
            }
        )
    }

    // MARK: - Presets

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Presets")
            ForEach(presets.indices, id: \.self) { index in
                HStack {
                    TextField("Name", text: Binding(
                        get: { presets[index].name },
                        set: { newValue in
                            presets[index].name = newValue
                            presetStore.save(presets)
                        }
                    ))
                    .textFieldStyle(.plain)
                    .padding(6)
                    .background(Color(nsColor: Theme.panel))
                    .cornerRadius(4)

                    Text(presets[index].modelID)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(nsColor: Theme.dim))

                    Spacer()

                    Button {
                        deletePreset(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(nsColor: Theme.red))
                }
            }
            Button("Restore Defaults") {
                presetStore.reset()
                presets = presetStore.presets
            }
            .font(.system(size: 12))
        }
    }

    private func deletePreset(at index: Int) {
        presets.remove(at: index)
        presetStore.save(presets)
    }

    // MARK: - Shared

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Color(nsColor: Theme.dim))
    }
}

/// One live Automation-permission status row (see `Permissions`). Computes
/// on `.onAppear`/refresh rather than every SwiftUI re-render, since
/// `AEDeterminePermissionToAutomateTarget` shells out to AppleEvents.
private struct PermissionRow: View {
    let name: String
    let bundleID: String
    @State private var status: String = "checking…"

    var body: some View {
        HStack {
            Text(name)
            Spacer()
            Text(status)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(color(for: status))
        }
        .onAppear { refresh() }
        .onTapGesture { refresh() }
    }

    private func refresh() {
        status = Permissions.automationStatus(for: bundleID)
    }

    private func color(for status: String) -> Color {
        switch status {
        case "granted": return Color(nsColor: Theme.cyan)
        case "denied": return Color(nsColor: Theme.red)
        default: return Color(nsColor: Theme.amber)
        }
    }
}

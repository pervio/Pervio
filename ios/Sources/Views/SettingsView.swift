import SwiftUI

/// Minimal app settings: the app language, the text size, the figure cache and
/// the link to the privacy policy. No placeholder sections are pre-built.
///
/// "App language" governs both the prompts the app writes FOR THE MODEL (builder
/// seeds, 背景 attachment scaffolding, workflow pointers — see PromptLanguage)
/// AND the app's own interface chrome (buttons, footers, confirmations — see
/// UIStrings). One switch, no split. Server-side templates (e.g. the morning
/// report) and market catalog copy keep their author's language — that boundary
/// is deliberate and out of this setting's scope.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// Backed by the same key PromptLanguage.current reads; absent = English.
    @AppStorage(PromptLanguage.defaultsKey) private var promptLanguageRaw
        = PromptLanguage.english.rawValue
    @AppStorage(TextSize.defaultsKey) private var textSizeRaw = TextSize.system.rawValue
    @State private var figureCacheBytes: Int64 = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(L.settingsLanguageLabel(), selection: $promptLanguageRaw) {
                        ForEach(PromptLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    Text(L.settingsLanguageFooter())
                }
                .listRowBackground(Palette.surface)

                Section {
                    Picker(L.settingsTextSize(), selection: $textSizeRaw) {
                        ForEach(TextSize.allCases) { s in
                            Text(s.displayName()).tag(s.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(L.settingsTextSizeFooter())
                }
                .listRowBackground(Palette.surface)

                Section {
                    LabeledContent(L.settingsFigureCache()) {
                        Text(ByteCountFormatter.string(fromByteCount: figureCacheBytes,
                                                       countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) {
                        Task.detached {
                            FigureStore.clearDisk()
                            let n = FigureStore.diskUsage()
                            await MainActor.run { figureCacheBytes = n }
                        }
                    } label: {
                        Text(L.settingsClearFigureCache())
                    }
                } header: {
                    Text(L.settingsStorageSection())
                } footer: {
                    Text(L.settingsStorageFooter())
                }
                .listRowBackground(Palette.surface)

                // The privacy policy, opened in the browser. It has to be
                // reachable from inside the app, not only from the store page
                // (App Review 5.1.1(i)).
                Section {
                    Link(destination: SiteLinks.privacy()) {
                        HStack {
                            Text(L.settingsPrivacyPolicy())
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .accessibilityIdentifier("settings-privacy")
                }
                .listRowBackground(Palette.surface)
            }
            .task {
                let n = await Task.detached { FigureStore.diskUsage() }.value
                figureCacheBytes = n
            }
            .pervioBackground()
            .pervioBar(L.settingsTitle(), back: false)
            .toolbar {
                BarItem(.confirmationAction) {
                    BarWord(text: L.done(), weight: .semibold) { dismiss() }
                }
            }
        }
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit
import Security

struct ContentView: View {
    @EnvironmentObject private var appUpdater: AppUpdater
    @State private var text: String = ""
    @State private var phrase: String = ""
    @State private var clean: Bool = false
    @State private var sourceName: String? = nil

    @State private var report: Report? = nil
    @State private var isRunning = false
    @State private var errorMessage: String? = nil
    @State private var dropTargeted = false

    enum ResultMode: Hashable { case cards, highlighted }
    @State private var viewMode: ResultMode = .cards
    @State private var enabledMetrics: Set<String> = []
    @State private var selectedSection: AppSection = .analysis
    @State private var chatDraft: String = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var backStack: [AppSection] = []
    @State private var forwardStack: [AppSection] = []
    @State private var searchExpanded = false
    @State private var searchText = ""
    @State private var aiSidebarVisible = true
    @State private var analysisRecords: [AnalysisRecord] = Self.loadAnalysisRecords()
    @State private var activeAnalysisRecordID: UUID? = nil
    @State private var chatMessages: [ChatMessage] = []
    @State private var isChatRunning = false
    @State private var aiErrorMessage: String? = nil
    @State private var apiKeyDraft: String = KeychainStore.openAIAPIKey() ?? ""
    @State private var hasOpenAIAPIKey = KeychainStore.openAIAPIKey() != nil
    @State private var availableOpenAIModels: [String] = Self.defaultOpenAIModels
    @State private var isLoadingModels = false
    @State private var modelLoadError: String? = nil
    @AppStorage("LangCheck.openAIModel") private var openAIModel = "gpt-5.5"
    @AppStorage("LangCheck.reasoningEffort") private var reasoningEffort = "low"
    @FocusState private var chatInputFocused: Bool

    private enum AppSection: String, CaseIterable, Identifiable {
        case analysis = "Analyze"
        case library = "Library"
        case history = "History"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .analysis: return "text.magnifyingglass"
            case .library: return "folder"
            case .history: return "clock.arrow.circlepath"
            case .settings: return "gearshape"
            }
        }
    }

    private var primarySections: [AppSection] { [.analysis, .library, .history] }
    private static let defaultOpenAIModels = ["gpt-5.5", "gpt-5.5-mini", "gpt-5.5-nano", "gpt-5.1", "gpt-5"]

    private struct AnalysisRecord: Codable, Identifiable {
        let id: UUID
        let createdAt: Date
        let title: String
        let text: String
        let phrase: String
        let clean: Bool
        let report: Report
        var chatMessages: [ChatMessage]?

        var words: Int { report.meta.words }
        var sentences: Int { report.meta.sentences }
    }

    private struct ChatMessage: Codable, Identifiable {
        enum Role: String, Codable, Equatable {
            case user
            case assistant

            var apiRole: String { rawValue }
        }

        let id: UUID
        let role: Role
        var content: String
        let createdAt: Date
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 245, max: 320)
        } detail: {
            mainShell
        }
        .frame(minWidth: 1120, minHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { goBack() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .disabled(backStack.isEmpty)
                .help("Back")

                Button { goForward() } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .disabled(forwardStack.isEmpty)
                .help("Forward")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if searchExpanded {
                    NativeSearchField(text: $searchText,
                                      placeholder: "Search",
                                      onCancel: collapseSearch)
                        .frame(width: 260, height: 28)
                } else {
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            searchExpanded = true
                        }
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .help("Search")
                }

                if selectedSection == .analysis {
                    Menu {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Rarity phrase")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("Optional phrase to score", text: $phrase)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                        }
                        .padding(.vertical, 4)

                        Divider()

                        Toggle("Strip salutations and closings", isOn: $clean)

                        if !phrase.isEmpty || clean {
                            Divider()
                            Button("Reset Analysis Options") {
                                phrase = ""
                                clean = false
                            }
                        }
                    } label: {
                        Label("Analyze Options", systemImage: "ellipsis.circle")
                    }
                    .help("Analyze options")

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            aiSidebarVisible.toggle()
                        }
                    } label: {
                        Label(aiSidebarVisible ? "Hide AI chat sidebar" : "Show AI chat sidebar",
                              systemImage: "sidebar.right")
                    }
                    .help(aiSidebarVisible ? "Hide AI chat sidebar" : "Show AI chat sidebar")
                }
            }
        }
    }

    // MARK: - App shell

    private var sidebar: some View {
        List(selection: sectionSelection) {
            Section {
                ForEach(primarySections) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
            }

            Section("Documents") {
                Label(sourceName ?? "No file loaded", systemImage: sourceName == nil ? "doc" : "doc.text")
                    .foregroundStyle(.secondary)
                if let report {
                    Label("\(report.meta.words) words", systemImage: "number")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Label(AppSection.settings.rawValue, systemImage: AppSection.settings.icon)
                    .tag(AppSection.settings)
            }
        }
        .listStyle(.sidebar)
    }

    private var sectionSelection: Binding<AppSection?> {
        Binding {
            selectedSection
        } set: { newValue in
            if let newValue {
                selectSection(newValue)
            }
        }
    }

    private var mainShell: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            switch selectedSection {
            case .analysis:
                analysisWorkspace
            case .library:
                recordsScreen(title: "Library",
                              emptyIcon: "folder",
                              emptyMessage: "Analyzed documents will appear here.",
                              records: libraryRecords)
            case .history:
                recordsScreen(title: "History",
                              emptyIcon: "clock.arrow.circlepath",
                              emptyMessage: "Analysis history will appear here.",
                              records: analysisRecords)
            case .settings:
                settingsScreen
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text(selectedSection.rawValue)
                .font(.headline.weight(.semibold))
            if selectedSection == .analysis, let report {
                Text("\(report.meta.words) words")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { openFile() } label: {
                Label("Open", systemImage: "folder")
            }
            Button { analyze() } label: {
                if isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing")
                    }
                } else {
                    Label("Analyze", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(selectedSection != .analysis || isRunning || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var analysisWorkspace: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                inputSection
                Divider()
                resultsSection
            }
            .frame(minWidth: 560)

            if aiSidebarVisible {
                Divider()

                assistantPanel
                    .frame(width: 360)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private func placeholderScreen(title: String, icon: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var libraryRecords: [AnalysisRecord] {
        var seen = Set<String>()
        return analysisRecords.filter { record in
            let key = record.title.lowercased()
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    @ViewBuilder
    private func recordsScreen(title: String,
                               emptyIcon: String,
                               emptyMessage: String,
                               records: [AnalysisRecord]) -> some View {
        if records.isEmpty {
            placeholderScreen(title: title, icon: emptyIcon, message: emptyMessage)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(records) { record in
                        recordRow(record)
                    }
                }
                .padding(16)
            }
        }
    }

    private func recordRow(_ record: AnalysisRecord) -> some View {
        Button {
            openRecord(record)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(record.words) words · \(record.sentences) sentences · \(formatRecordDate(record.createdAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(record.report.metrics.prefix(3).map(\.title).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private var settingsScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Settings")
                        .font(.largeTitle.weight(.semibold))
                    Text("Configure LangCheck's AI behavior and local app preferences.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("API Settings")
                        .font(.title3.weight(.semibold))

                    settingsGroup {
                        settingsRow(title: "OpenAI API key",
                                    subtitle: hasOpenAIAPIKey ? "A key is saved in macOS Keychain." : "Required for document chat.") {
                            if hasOpenAIAPIKey {
                                Label("Saved", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption.weight(.semibold))
                            }
                        }

                        Divider()

                        SecureField(hasOpenAIAPIKey ? "Replace saved API key" : "OpenAI API key", text: $apiKeyDraft)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Button(hasOpenAIAPIKey ? "Update Key" : "Save Key") { saveAPIKey() }
                                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Remove Key") { removeAPIKey() }
                                .disabled(!hasOpenAIAPIKey)
                            Spacer()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Model Behavior")
                        .font(.title3.weight(.semibold))

                    settingsGroup {
                        settingsRow(title: "Model",
                                    subtitle: "Choose one of the models available to your API key.") {
                            Picker("", selection: $openAIModel) {
                                ForEach(modelChoices, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }

                        Divider()

                        settingsRow(title: "Available models",
                                    subtitle: modelLoadError ?? (hasOpenAIAPIKey ? "Refresh from your OpenAI account." : "Save an API key to refresh model availability.")) {
                            Button {
                                refreshAvailableModels()
                            } label: {
                                if isLoadingModels {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                }
                            }
                            .disabled(!hasOpenAIAPIKey || isLoadingModels)
                        }

                        Divider()

                        settingsRow(title: "Reasoning",
                                    subtitle: "Controls the model's reasoning effort for document chat.") {
                            Picker("", selection: $reasoningEffort) {
                                Text("None").tag("none")
                                Text("Low").tag("low")
                                Text("Medium").tag("medium")
                                Text("High").tag("high")
                                Text("XHigh").tag("xhigh")
                            }
                            .labelsHidden()
                            .frame(width: 220)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Privacy")
                        .font(.title3.weight(.semibold))

                    settingsGroup {
                        settingsRow(title: "OpenAI storage",
                                    subtitle: "Requests are sent with store disabled.") {
                            Text("Off")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        settingsRow(title: "Local analysis history",
                                    subtitle: "Saved locally in UserDefaults, capped at 200 analyses.") {
                            Text("\(analysisRecords.count)")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Updates")
                        .font(.title3.weight(.semibold))

                    settingsGroup {
                        settingsRow(title: "App updates",
                                    subtitle: appUpdater.canCheckForUpdates
                                    ? "Check for a newer LangCheck build from the configured update feed."
                                    : "Updates are not configured for this local build.") {
                            Button("Check for Updates") {
                                appUpdater.checkForUpdates()
                            }
                            .disabled(!appUpdater.canCheckForUpdates)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 30)
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    private var modelChoices: [String] {
        var choices = availableOpenAIModels
        if !choices.contains(openAIModel) {
            choices.insert(openAIModel, at: 0)
        }
        return choices
    }

    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.12)))
    }

    private func settingsRow<Trailing: View>(title: String,
                                             subtitle: String,
                                             @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing()
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.18),
                                  style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1,
                                                     dash: dropTargeted ? [6] : []))
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .padding(8)
                    .scrollContentBackground(.hidden)
                if text.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(dropTargeted ? "Drop to load" : "Paste or type text here")
                            .font(.callout.weight(.semibold))
                        Text("Drop a .txt, .doc, .docx, .rtf, or PDF file to extract text.")
                            .font(.caption)
                    }
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                }
            }
            .frame(height: 170)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                handleDrop(providers)
            }

            analysisOptionsSummary
        }
        .padding(16)
    }

    @ViewBuilder
    private var analysisOptionsSummary: some View {
        if !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || clean {
            HStack(spacing: 8) {
                Label("Options", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.semibold))
                if clean {
                    Text("Strip salutations")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Phrase: \(phrase)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer()
            }
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsSection: some View {
        if let report {
            VStack(spacing: 0) {
                controlBar(report)
                Divider()
                if viewMode == .cards {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            let metrics = filteredMetrics(report.metrics)
                            if metrics.isEmpty {
                                ContentUnavailableView("No matches",
                                                       systemImage: "magnifyingglass",
                                                       description: Text("Try a different search term."))
                                    .frame(maxWidth: .infinity, minHeight: 260)
                            }
                            ForEach(Array(metrics.enumerated()), id: \.element.id) { idx, metric in
                                MetricCard(index: idx + 1,
                                           metric: metric,
                                           canHighlight: !metric.highlightSpans.isEmpty,
                                           color: MetricColors.color(for: metric.key),
                                           showInText: { showInText(metric.key) })
                            }
                        }
                        .padding(16)
                    }
                } else {
                    highlightedPane(report)
                }
            }
        } else if let errorMessage {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Analysis failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                Text("No results yet").font(.headline)
                Text("Drop or open a .txt file, then run analysis.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }

    private func controlBar(_ report: Report) -> some View {
        HStack(spacing: 10) {
            Text("\(report.meta.words) words · \(report.meta.sentences) sentences")
                .font(.subheadline.weight(.semibold))
            if let sourceName {
                Text("· \(sourceName)").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $viewMode) {
                Text("Cards").tag(ResultMode.cards)
                Text("Highlighted text").tag(ResultMode.highlighted)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 250)
            Button { copyReport() } label: { Image(systemName: "doc.on.doc") }
                .help("Copy report")
            Button { saveReport() } label: { Image(systemName: "square.and.arrow.down") }
                .help("Save report")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var assistantPanel: some View {
        VStack(spacing: 0) {
            chatConversationArea
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 10) {
                chatInputField

                HStack(spacing: 12) {
                    Menu {
                        Button("Add current analyzer text") {
                            appendCurrentTextReference()
                        }
                        Button("Upload files...") {
                            openFile()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "paperclip")
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Menu {
                        Button {
                            reasoningEffort = "none"
                        } label: {
                            reasoningMenuLabel("None", value: "none")
                        }
                        Button {
                            reasoningEffort = "low"
                        } label: {
                            reasoningMenuLabel("Low", value: "low")
                        }
                        Button {
                            reasoningEffort = "medium"
                        } label: {
                            reasoningMenuLabel("Medium", value: "medium")
                        }
                        Button {
                            reasoningEffort = "high"
                        } label: {
                            reasoningMenuLabel("High", value: "high")
                        }
                        Button {
                            reasoningEffort = "xhigh"
                        } label: {
                            reasoningMenuLabel("XHigh", value: "xhigh")
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Reasoning: \(reasoningLabel(reasoningEffort))")
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .menuStyle(.borderlessButton)

                    Button { } label: {
                        Image(systemName: "binoculars.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(true)

                    Button { } label: {
                        Image(systemName: "bolt.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(true)
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var chatConversationArea: some View {
        if chatMessages.isEmpty && aiErrorMessage == nil {
            ZStack {
                Color(nsColor: .windowBackgroundColor)

                VStack(spacing: 6) {
                    Text("New Conversation")
                    if report == nil {
                        Text("Analyze a document first")
                            .font(.callout.weight(.semibold))
                    } else if !hasOpenAIAPIKey {
                        Text("Add an OpenAI API key to start")
                            .font(.callout.weight(.semibold))
                    }
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(chatMessages) { message in
                        chatMessageBubble(message)
                    }

                    if let aiErrorMessage {
                        Text(aiErrorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
                    }
                }
                .padding(14)
            }
        }
    }

    private func chatMessageBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.role == .user { Spacer(minLength: 32) }
            chatMessageBody(message)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(message.role == .user
                              ? Color.accentColor.opacity(0.16)
                              : Color(nsColor: .controlBackgroundColor))
                )
                .frame(maxWidth: 290, alignment: message.role == .user ? .trailing : .leading)
            if message.role == .assistant { Spacer(minLength: 32) }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private func chatMessageBody(_ message: ChatMessage) -> some View {
        if message.role == .assistant {
            ChatMarkdownView(content: message.content.isEmpty ? " " : message.content)
        } else {
            Text(message.content.isEmpty ? " " : message.content)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    private var chatInputField: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField(chatPlaceholder, text: $chatDraft)
                    .textFieldStyle(.plain)
                    .focused($chatInputFocused)
                    .onSubmit { sendChatMessage() }
                    .disabled(!canEditChat)
                Button { sendChatMessage() } label: {
                    if isChatRunning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(canSendChat ? Color.accentColor : Color.secondary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canSendChat || isChatRunning)
                .help("Ask about this document")
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(chatInputFocused ? Color.accentColor.opacity(0.65) : Color.clear, lineWidth: 1)
        }
        .shadow(color: chatInputFocused ? Color.red.opacity(0.35) : .clear, radius: 14, x: -10, y: 0)
        .shadow(color: chatInputFocused ? Color.orange.opacity(0.30) : .clear, radius: 16, x: -3, y: 8)
        .shadow(color: chatInputFocused ? Color.cyan.opacity(0.35) : .clear, radius: 16, x: 10, y: 0)
        .animation(.easeInOut(duration: 0.16), value: chatInputFocused)
    }

    private var canEditChat: Bool {
        report != nil && hasOpenAIAPIKey && !isChatRunning
    }

    private var canSendChat: Bool {
        canEditChat && !chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var chatPlaceholder: String {
        if report == nil { return "Analyze first to chat" }
        if !hasOpenAIAPIKey { return "Add API key in Settings" }
        return "Ask about this document"
    }

    private func reasoningLabel(_ value: String) -> String {
        switch value {
        case "none": return "None"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "XHigh"
        default: return value.capitalized
        }
    }

    @ViewBuilder
    private func reasoningMenuLabel(_ label: String, value: String) -> some View {
        if reasoningEffort == value {
            Label(label, systemImage: "checkmark")
        } else {
            Text(label)
        }
    }

    private func highlightedPane(_ report: Report) -> some View {
        let highlightable = report.metrics.filter { !$0.highlightSpans.isEmpty }
        return VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(highlightable) { legendChip($0) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            Divider()
            HighlightedTextView(text: report.text ?? text,
                                metrics: report.metrics,
                                enabled: enabledMetrics)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func legendChip(_ metric: Metric) -> some View {
        let on = enabledMetrics.contains(metric.key)
        let color = MetricColors.color(for: metric.key)
        return Button {
            if on { enabledMetrics.remove(metric.key) } else { enabledMetrics.insert(metric.key) }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(shortLabel(metric.key)).font(.caption)
                Text("\(metric.highlightSpans.count)")
                    .font(.caption.bold()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(on ? color.opacity(0.18) : Color.secondary.opacity(0.08)))
            .overlay(Capsule().strokeBorder(on ? color.opacity(0.6) : Color.secondary.opacity(0.25)))
            .opacity(on ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .help(metric.title)
    }

    private func shortLabel(_ key: String) -> String {
        switch key {
        case "rather": return "rather"
        case "in_before_gerund": return "in + gerund"
        case "contractions": return "contractions"
        case "will_shall": return "will / shall"
        case "possessive_gerund": return "poss + gerund"
        case "dropped_article": return "dropped article"
        case "complementizer": return "which / that"
        case "is_this": return "is this"
        case "top_degree_adverbs": return "degree adverbs"
        default: return key
        }
    }

    private func showInText(_ key: String) {
        enabledMetrics = [key]
        viewMode = .highlighted
    }

    private func filteredMetrics(_ metrics: [Metric]) -> [Metric] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return metrics }
        return metrics.filter { metric in
            metric.title.localizedCaseInsensitiveContains(query)
            || metric.headline.localizedCaseInsensitiveContains(query)
            || metric.note.localizedCaseInsensitiveContains(query)
            || metric.examples.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func collapseSearch() {
        withAnimation(.easeInOut(duration: 0.16)) {
            searchExpanded = false
            searchText = ""
        }
    }

    private func selectSection(_ section: AppSection) {
        guard selectedSection != section else { return }
        backStack.append(selectedSection)
        forwardStack.removeAll()
        selectedSection = section
    }

    private func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(selectedSection)
        selectedSection = previous
    }

    private func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(selectedSection)
        selectedSection = next
    }

    // MARK: - Analysis library

    private static let analysisRecordsKey = "LangCheck.analysisRecords.v1"

    private static func loadAnalysisRecords() -> [AnalysisRecord] {
        guard let data = UserDefaults.standard.data(forKey: analysisRecordsKey),
              let records = try? JSONDecoder().decode([AnalysisRecord].self, from: data) else {
            return []
        }
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    private func persistAnalysisRecords() {
        let records = Array(analysisRecords.prefix(200))
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.analysisRecordsKey)
        }
    }

    private func storeAnalysis(text: String,
                               phrase: String,
                               clean: Bool,
                               sourceName: String?,
                               report: Report) {
        let title = sourceName ?? report.meta.source ?? "Untitled document"
        let record = AnalysisRecord(id: UUID(),
                                    createdAt: Date(),
                                    title: title,
                                    text: text,
                                    phrase: phrase,
                                    clean: clean,
                                    report: report,
                                    chatMessages: [])
        analysisRecords.insert(record, at: 0)
        activeAnalysisRecordID = record.id
        analysisRecords = Array(analysisRecords.prefix(200))
        persistAnalysisRecords()
    }

    private func persistCurrentChatMessages() {
        guard let activeAnalysisRecordID,
              let index = analysisRecords.firstIndex(where: { $0.id == activeAnalysisRecordID }) else {
            return
        }
        analysisRecords[index].chatMessages = chatMessages
        persistAnalysisRecords()
    }

    private func openRecord(_ record: AnalysisRecord) {
        activeAnalysisRecordID = record.id
        text = record.text
        phrase = record.phrase
        clean = record.clean
        sourceName = record.title
        report = record.report
        chatMessages = record.chatMessages ?? []
        chatDraft = ""
        aiErrorMessage = nil
        enabledMetrics = Set(record.report.metrics
            .filter { !$0.highlightSpans.isEmpty }
            .map { $0.key })
        viewMode = .cards
        errorMessage = nil
        selectSection(.analysis)
    }

    private func formatRecordDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - AI chat

    private func saveAPIKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try KeychainStore.saveOpenAIAPIKey(key)
            hasOpenAIAPIKey = true
            aiErrorMessage = nil
            refreshAvailableModels()
        } catch {
            aiErrorMessage = "Could not save API key: \(error.localizedDescription)"
        }
    }

    private func sendChatMessage() {
        guard canSendChat,
              let report,
              let apiKey = KeychainStore.openAIAPIKey() else { return }

        let question = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        chatDraft = ""
        aiErrorMessage = nil
        chatMessages.append(ChatMessage(id: UUID(), role: .user, content: question, createdAt: Date()))
        let assistantID = UUID()
        chatMessages.append(ChatMessage(id: assistantID, role: .assistant, content: "", createdAt: Date()))
        persistCurrentChatMessages()

        let priorMessages = chatMessages.dropLast(2)
        let documentText = text
        let documentTitle = sourceName ?? "Untitled document"
        isChatRunning = true

        Task.detached(priority: .userInitiated) {
            do {
                try await OpenAIChatService.streamDocumentAnswer(
                    apiKey: apiKey,
                    model: openAIModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "gpt-5.5" : openAIModel,
                    reasoningEffort: reasoningEffort,
                    documentTitle: documentTitle,
                    documentText: documentText,
                    report: report,
                    priorMessages: priorMessages.map { OpenAIChatService.PriorMessage(role: $0.role.apiRole,
                                                                                       content: $0.content) },
                    question: question
                ) { delta in
                    await MainActor.run {
                        if let index = self.chatMessages.firstIndex(where: { $0.id == assistantID }) {
                            self.chatMessages[index].content += delta
                            self.persistCurrentChatMessages()
                        }
                    }
                }

                await MainActor.run {
                    self.persistCurrentChatMessages()
                    self.isChatRunning = false
                }
            } catch {
                await MainActor.run {
                    if let index = self.chatMessages.firstIndex(where: { $0.id == assistantID }),
                       self.chatMessages[index].content.isEmpty {
                        self.chatMessages.remove(at: index)
                    }
                    self.aiErrorMessage = error.localizedDescription
                    self.persistCurrentChatMessages()
                    self.isChatRunning = false
                }
            }
        }
    }

    private func removeAPIKey() {
        do {
            try KeychainStore.deleteOpenAIAPIKey()
            hasOpenAIAPIKey = false
            apiKeyDraft = ""
            availableOpenAIModels = Self.defaultOpenAIModels
            modelLoadError = nil
            aiErrorMessage = nil
        } catch {
            aiErrorMessage = "Could not remove API key: \(error.localizedDescription)"
        }
    }

    private func refreshAvailableModels() {
        guard let apiKey = KeychainStore.openAIAPIKey() else { return }
        isLoadingModels = true
        modelLoadError = nil

        Task.detached(priority: .userInitiated) {
            do {
                let models = try await OpenAIChatService.fetchAvailableModels(apiKey: apiKey)
                await MainActor.run {
                    self.availableOpenAIModels = models.isEmpty ? Self.defaultOpenAIModels : models
                    if !self.availableOpenAIModels.contains(self.openAIModel),
                       let first = self.availableOpenAIModels.first {
                        self.openAIModel = first
                    }
                    self.isLoadingModels = false
                }
            } catch {
                await MainActor.run {
                    self.modelLoadError = error.localizedDescription
                    self.isLoadingModels = false
                }
            }
        }
    }

    private func appendCurrentTextReference() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let title = sourceName ?? "current analyzer text"
        let reference = "[Using \(title) as context]"
        if chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chatDraft = reference
        } else if !chatDraft.contains(reference) {
            chatDraft += "\n\(reference)"
        }
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let direct = item as? URL {
                url = direct
            } else if let str = item as? String,
                      let resolved = InputResolver.contents(forPathLike: str) {
                DispatchQueue.main.async {
                    self.text = resolved.text
                    self.sourceName = resolved.name
                    self.report = nil
                    self.activeAnalysisRecordID = nil
                    self.chatMessages = []
                    self.chatDraft = ""
                    self.aiErrorMessage = nil
                    self.errorMessage = nil
                }
                return
            }
            if let url { loadFile(url) }
        }
        return true
    }

    private func openFile() {
        let panel = NSOpenPanel()
        var allowedTypes: [UTType] = [.plainText, .text, .pdf, .rtf, .rtfd]
        if let doc = UTType(filenameExtension: "doc") { allowedTypes.append(doc) }
        if let docx = UTType(filenameExtension: "docx") { allowedTypes.append(docx) }
        panel.allowedContentTypes = allowedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            loadFile(url)
        }
    }

    private func loadFile(_ url: URL) {
        let loaded = Self.extractText(from: url)
        DispatchQueue.main.async {
            if let content = loaded {
                self.text = content
                self.sourceName = url.lastPathComponent
                self.report = nil
                self.activeAnalysisRecordID = nil
                self.enabledMetrics = []
                self.viewMode = .cards
                self.chatMessages = []
                self.chatDraft = ""
                self.aiErrorMessage = nil
                self.errorMessage = nil
            } else {
                self.errorMessage = "Could not read \(url.lastPathComponent). Try a text, Word, RTF, or PDF file."
            }
        }
    }

    private static func extractText(from url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return extractPDFText(from: url)
        }
        if ["doc", "docx", "rtf", "rtfd"].contains(ext),
           let attributed = try? NSAttributedString(url: url,
                                                    options: [:],
                                                    documentAttributes: nil) {
            let result = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty { return result }
        }
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        if let data = try? Data(contentsOf: url) {
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        }
        return nil
    }

    private static func extractPDFText(from url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
        let result = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private func clearAll() {
        text = ""
        phrase = ""
        report = nil
        activeAnalysisRecordID = nil
        errorMessage = nil
        sourceName = nil
        viewMode = .cards
        enabledMetrics = []
        chatMessages = []
        chatDraft = ""
        aiErrorMessage = nil
    }

    private func analyze() {
        // If the box holds just a file path (e.g. a dropped file inserted its
        // path instead of its text), swap in the file's actual contents.
        if let resolved = InputResolver.contents(forPathLike: text) {
            text = resolved.text
            sourceName = resolved.name
        }
        let snapText = text
        let snapPhrase = phrase
        let snapClean = clean
        let snapSourceName = sourceName
        isRunning = true
        errorMessage = nil
        Task.detached(priority: .userInitiated) {
            do {
                let result = try PythonEngine.analyze(text: snapText, phrase: snapPhrase, clean: snapClean)
                await MainActor.run {
                    self.report = result
                    self.enabledMetrics = Set(result.metrics
                        .filter { !$0.highlightSpans.isEmpty }
                        .map { $0.key })
                    self.viewMode = .cards
                    self.chatMessages = []
                    self.chatDraft = ""
                    self.aiErrorMessage = nil
                    self.storeAnalysis(text: snapText,
                                       phrase: snapPhrase,
                                       clean: snapClean,
                                       sourceName: snapSourceName,
                                       report: result)
                    self.isRunning = false
                }
            } catch {
                let message = (error as? EngineError)?.message ?? error.localizedDescription
                await MainActor.run {
                    self.report = nil
                    self.errorMessage = message
                    self.isRunning = false
                }
            }
        }
    }

    // MARK: - Report export

    private func plainText(_ report: Report) -> String {
        var lines: [String] = []
        let rule = String(repeating: "=", count: 60)
        lines.append(rule)
        lines.append("LangCheck — stylometric report")
        lines.append(rule)
        lines.append("\(report.meta.words) words · \(report.meta.sentences) sentences · \(report.meta.characters) characters")
        if let sourceName { lines.append("source: \(sourceName)") }
        lines.append("")
        for (i, m) in report.metrics.enumerated() {
            lines.append("\(i + 1). \(m.title)")
            lines.append("   \(m.headline)")
            for ex in m.examples { lines.append("     • \(ex)") }
            if !m.note.isEmpty { lines.append("   (\(m.note))") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func copyReport() {
        guard let report else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plainText(report), forType: .string)
    }

    private func saveReport() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "langcheck_report.txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? plainText(report).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Chat Markdown

private struct ChatMarkdownView: View {
    let content: String

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case numbered(number: String, text: String)
        case code(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [Block] {
        Self.parse(content)
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inlineMarkdown(text))
                .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)

        case .paragraph(let text):
            Text(Self.inlineMarkdown(text))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(Self.inlineMarkdown(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(Self.inlineMarkdown(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .code(let text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.16)))
        }
    }

    private static func parse(_ content: String) -> [Block] {
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var isInCodeBlock = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll()
        }

        for rawLine in normalizedMarkdown(content).components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if isInCodeBlock {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    isInCodeBlock = false
                } else {
                    flushParagraph()
                    isInCodeBlock = true
                }
                continue
            }

            if isInCodeBlock {
                codeLines.append(rawLine)
                continue
            }

            guard !line.isEmpty else {
                flushParagraph()
                continue
            }

            if let heading = headingBlock(from: line) {
                flushParagraph()
                blocks.append(heading)
            } else if let bullet = bulletText(from: line) {
                flushParagraph()
                blocks.append(.bullet(bullet))
            } else if let numbered = numberedBlock(from: line) {
                flushParagraph()
                blocks.append(numbered)
            } else {
                paragraphLines.append(line)
            }
        }

        if isInCodeBlock, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()

        return blocks.isEmpty ? [.paragraph(content)] : blocks
    }

    private static func normalizedMarkdown(_ content: String) -> String {
        var result = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let sectionLabels = [
            "Formal/old-fashioned modal use",
            "Low contraction rate",
            "Rather as degree adverb",
            "Possessive + gerund",
            "Dropped/missing articles",
            "Complementizer deletion",
            "Repeated cataphoric",
            "Rare/marked spellings and words",
            "Overall"
        ]

        for label in sectionLabels {
            result = result.replacingOccurrences(of: "\(label):", with: "\n\n**\(label):**")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func headingBlock(from line: String) -> Block? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...4).contains(level) else { return nil }
        let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: level, text: text)
    }

    private static func bulletText(from line: String) -> String? {
        for prefix in ["- ", "* ", "• "] {
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func numberedBlock(from line: String) -> Block? {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2,
              parts[0].hasSuffix("."),
              parts[0].dropLast().allSatisfy(\.isNumber) else {
            return nil
        }
        return .numbered(number: String(parts[0].dropLast()),
                         text: String(parts[1]).trimmingCharacters(in: .whitespaces))
    }

    private static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

// MARK: - Native search field

struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.bezelStyle = .roundedBezel
        field.controlSize = .large

        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }

        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        context.coordinator.text = $text
        context.coordinator.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCancel: onCancel)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var onCancel: () -> Void

        init(text: Binding<String>, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onCancel()
                return true
            }
            return false
        }
    }
}

// MARK: - OpenAI chat

enum KeychainStore {
    private static let service = "com.langcheck.openai"
    private static let account = "api-key"

    static func openAIAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    static func saveOpenAIAPIKey(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func deleteOpenAIAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        }
    }
}

enum OpenAIChatService {
    struct PriorMessage {
        let role: String
        let content: String
    }

    private struct ModelsResponse: Decodable {
        let data: [ModelItem]
    }

    private struct ModelItem: Decodable {
        let id: String
    }

    private struct StreamEvent: Decodable {
        let type: String?
        let delta: String?
        let response: ResponseError?
        let error: ResponseError?
    }

    private struct ResponseError: Decodable {
        let message: String?
    }

    static func fetchAvailableModels(apiKey: String) async throws -> [String] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ChatError.requestFailed(status: http.statusCode, body: body)
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data
            .map(\.id)
            .filter { id in
                id.hasPrefix("gpt-") || id.hasPrefix("o")
            }
            .filter { id in
                !id.contains("audio")
                && !id.contains("image")
                && !id.contains("tts")
                && !id.contains("transcribe")
                && !id.contains("realtime")
                && !id.contains("embedding")
            }
            .sorted { lhs, rhs in
                modelSortKey(lhs) < modelSortKey(rhs)
            }
    }

    private static func modelSortKey(_ model: String) -> String {
        if model == "gpt-5.5" { return "000-\(model)" }
        if model.hasPrefix("gpt-5") { return "001-\(model)" }
        if model.hasPrefix("gpt-4") { return "002-\(model)" }
        return "999-\(model)"
    }

    static func streamDocumentAnswer(apiKey: String,
                                     model: String,
                                     reasoningEffort: String,
                                     documentTitle: String,
                                     documentText: String,
                                     report: Report,
                                     priorMessages: [PriorMessage],
                                     question: String,
                                     onDelta: @escaping (String) async -> Void) async throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody(model: model,
                                                                                  reasoningEffort: reasoningEffort,
                                                                                  documentTitle: documentTitle,
                                                                                  documentText: documentText,
                                                                                  report: report,
                                                                                  priorMessages: priorMessages,
                                                                                  question: question))

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines {
                body += line
            }
            throw ChatError.requestFailed(status: http.statusCode, body: body)
        }

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(StreamEvent.self, from: data) else {
                continue
            }
            if let message = event.error?.message ?? event.response?.message {
                throw ChatError.api(message)
            }
            if event.type == "response.output_text.delta", let delta = event.delta {
                await onDelta(delta)
            }
        }
    }

    private static func requestBody(model: String,
                                    reasoningEffort: String,
                                    documentTitle: String,
                                    documentText: String,
                                    report: Report,
                                    priorMessages: [PriorMessage],
                                    question: String) throws -> [String: Any] {
        let reportJSON = String(data: try JSONEncoder().encode(report), encoding: .utf8) ?? "{}"
        let metricEvidence = report.metrics.enumerated().map { index, metric in
            let examples = metric.examples.prefix(5).map { "    - \($0)" }.joined(separator: "\n")
            return """
            \(index + 1). \(metric.title)
               Result: \(metric.headline)
               Note: \(metric.note.isEmpty ? "(none)" : metric.note)
               Examples:
            \(examples.isEmpty ? "    - (none)" : examples)
            """
        }
        .joined(separator: "\n\n")
        let transcript = priorMessages.suffix(12).map { "\($0.role.uppercased()): \($0.content)" }
            .joined(separator: "\n\n")
        let context = """
        Document title: \(documentTitle)

        LangCheck Python analyzer summary:
        - Words: \(report.meta.words)
        - Sentences: \(report.meta.sentences)
        - Characters: \(report.meta.characters)

        LangCheck metric evidence:
        \(metricEvidence)

        Document text:
        \(documentText)

        Full LangCheck report JSON:
        \(reportJSON)

        Prior conversation:
        \(transcript.isEmpty ? "(none)" : transcript)

        User question:
        \(question)
        """

        return [
            "model": model,
            "store": false,
            "stream": true,
            "reasoning": ["effort": reasoningEffort],
            "instructions": """
            You are LangCheck's document analysis assistant. The LangCheck report is the output of the app's local Python analysis algorithms; treat it as primary evidence for style, counts, examples, and metric conclusions. Answer only using the provided document text, metric evidence, and LangCheck report JSON. If the answer is not supported by that context, say so.

            Use structured Markdown. Never answer as one dense paragraph. Prefer:
            - a short direct answer first
            - bullet points grouped by metric or theme
            - exact counts and metric names when relevant
            - short quoted examples from the supplied text when useful

            Do not invent facts about the author or case beyond the supplied text.
            """,
            "input": context,
        ]
    }

    enum ChatError: LocalizedError {
        case requestFailed(status: Int, body: String)
        case api(String)

        var errorDescription: String? {
            switch self {
            case .requestFailed(let status, let body):
                return "OpenAI request failed (\(status)). \(body)"
            case .api(let message):
                return message
            }
        }
    }
}

// MARK: - Metric card

struct MetricCard: View {
    let index: Int
    let metric: Metric
    var canHighlight: Bool = false
    var color: Color = .accentColor
    var showInText: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if canHighlight {
                    Circle().fill(color).frame(width: 9, height: 9)
                }
                Text("\(index).  \(metric.title)")
                    .font(.headline)
                Spacer()
                if canHighlight {
                    Button(action: showInText) {
                        Label("Show in text", systemImage: "highlighter")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            Text(metric.headline)
                .font(.body)
                .foregroundStyle(Color.accentColor)
                .textSelection(.enabled)

            if !metric.examples.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(metric.examples.enumerated()), id: \.offset) { _, ex in
                        Text("•  \(ex)")
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 6)
            }

            if !metric.note.isEmpty {
                Text(metric.note)
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.15))
        )
    }
}

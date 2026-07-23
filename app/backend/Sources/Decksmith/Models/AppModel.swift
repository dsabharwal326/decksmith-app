import SwiftUI
import Foundation

enum AppPhase {
    case idle
    case processing
    case results
    case exporting
}

enum SidebarItem: String, Hashable, CaseIterable {
    case upload   = "upload"
    case topic    = "topic"
    case history  = "history"
    case settings = "settings"
}

@Observable
final class AppModel {
    // ── Phase ──────────────────────────────────────────────
    var phase: AppPhase = .idle

    // ── Input ──────────────────────────────────────────────
    var uploadedFiles: [URL] = []
    var cardText: String = ""           // raw text parsed from dropped files
    var deckName: String = "My Deck"
    var classify: Bool = true

    // ── Topic generator ────────────────────────────────────
    var topicInput: String = ""
    var topicSpecialty: String = "Any / General"
    var topicCardCount: Int = 20

    // ── Processing state ───────────────────────────────────
    var processingStatus: String = ""
    var processingProgress: Double = 0   // 0–1

    // ── Results ────────────────────────────────────────────
    var parsedNotes: [NoteModel] = []
    var validationResults: [ValidationResult] = []
    var totalCards: Int = 0
    var subdeckCounts: [(name: String, count: Int)] = []

    // ── Export ─────────────────────────────────────────────
    var builtApkgData: Data?
    var errorMessage: String?

    // ── History ────────────────────────────────────────────
    var history: [HistoryEntry] = []

    // ── Settings ───────────────────────────────────────────
    var apiBaseURL: String = UserDefaults.standard.string(forKey: "apiBaseURL") ?? "http://localhost:8503"
    var serviceKey: String = UserDefaults.standard.string(forKey: "serviceKey") ?? ""
    var selectedProvider: String = UserDefaults.standard.string(forKey: "selectedProvider") ?? "anthropic"

    // ── Service ────────────────────────────────────────────
    private(set) lazy var api: DecksmithAPI = DecksmithAPI(model: self)

    // ── Actions ────────────────────────────────────────────
    func addFiles(_ urls: [URL]) {
        uploadedFiles = urls
        cardText = urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                       .joined(separator: "\n")
    }

    func reset() {
        uploadedFiles = []
        cardText = ""
        parsedNotes = []
        validationResults = []
        totalCards = 0
        subdeckCounts = []
        builtApkgData = nil
        errorMessage = nil
        phase = .idle
    }

    func saveSettings() {
        UserDefaults.standard.set(apiBaseURL, forKey: "apiBaseURL")
        UserDefaults.standard.set(serviceKey, forKey: "serviceKey")
        UserDefaults.standard.set(selectedProvider, forKey: "selectedProvider")
        api = DecksmithAPI(model: self)
    }
}

// ── Supporting models ──────────────────────────────────────

struct NoteModel: Identifiable {
    let id = UUID()
    var noteType: String
    var front: String
    var back: String
    var extra: String
    var tags: [String]
}

struct ValidationResult: Identifiable {
    let id = UUID()
    var index: Int
    var status: String     // "valid" | "fixable" | "invalid"
    var error: String
    var fixDescription: String
    var preview: String
    var fixedNote: NoteModel?
}

struct HistoryEntry: Identifiable {
    let id = UUID()
    var deckName: String
    var cardCount: Int
    var date: Date
    var apkgData: Data
}

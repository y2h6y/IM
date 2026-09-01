import Foundation
import Combine

@MainActor
class SearchViewModel: ObservableObject {
    @Published var query   = ""
    @Published var results: [SearchResult] = []
    @Published var isSearching = false

    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        $query
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleSearch() }
            .store(in: &cancellables)
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            // 300 ms debounce
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.performSearch()
        }
    }

    func performSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; return }

        isSearching = true
        defer { isSearching = false }

        // FTS / LIKE search runs synchronously on a GRDB read connection —
        // wrap in a detached task to avoid blocking the main actor.
        let rawResults: [(message: LocalMessage, snippet: String)] = await Task.detached(priority: .userInitiated) {
            DatabaseService.shared.searchMessagesWithSnippet(query: q)
        }.value

        let conversations = AppState.shared.conversations
        results = rawResults.map { (msg, snippet) in
            SearchResult(
                message:      msg,
                snippet:      snippet,
                conversation: conversations.first { $0.id == msg.conversationId }
            )
        }
    }

    func clear() {
        query   = ""
        results = []
    }
}

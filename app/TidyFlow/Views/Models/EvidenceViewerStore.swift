import Foundation

struct EvidenceTextChunk: Identifiable, Equatable {
    let id: String
    let itemID: String
    let pageOffset: UInt64
    let chunkIndex: Int
    let text: String

    init(itemID: String, pageOffset: UInt64, chunkIndex: Int, text: String) {
        self.id = "\(itemID)::\(pageOffset)::\(chunkIndex)"
        self.itemID = itemID
        self.pageOffset = pageOffset
        self.chunkIndex = chunkIndex
        self.text = text
    }
}

struct EvidenceTextPagePayload {
    let content: [UInt8]
    let nextOffset: UInt64
    let totalSizeBytes: UInt64
    let eof: Bool
}

final class EvidenceViewerStore: ObservableObject {
    @Published private(set) var currentItemID: String?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isPaging: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var textChunks: [EvidenceTextChunk] = []
    @Published private(set) var nextOffset: UInt64 = 0
    @Published private(set) var hasMoreText: Bool = false
    @Published private(set) var byteCount: Int = 0

    func beginLoading(itemID: String) {
        currentItemID = itemID
        isLoading = true
        isPaging = false
        errorMessage = nil
        textChunks = []
        nextOffset = 0
        hasMoreText = false
        byteCount = 0
    }

    func beginPaging(itemID: String) {
        guard currentItemID == itemID else { return }
        isPaging = true
        errorMessage = nil
    }

    func clear() {
        currentItemID = nil
        isLoading = false
        isPaging = false
        errorMessage = nil
        textChunks = []
        nextOffset = 0
        hasMoreText = false
        byteCount = 0
    }

    func clearIfCurrentItemMissing(_ itemIDs: Set<String>) -> Bool {
        guard let currentItemID, !itemIDs.contains(currentItemID) else { return false }
        clear()
        return true
    }

    func applyImageLoadResult(itemID: String, byteCount: Int, errorMessage: String?) {
        guard currentItemID == itemID else { return }
        isLoading = false
        isPaging = false
        self.byteCount = byteCount
        self.errorMessage = errorMessage
    }

    func applyTextPage(
        itemID: String,
        offset: UInt64,
        payload: EvidenceTextPagePayload?,
        reset: Bool,
        errorMessage: String?
    ) {
        guard currentItemID == itemID else { return }
        isLoading = false
        isPaging = false
        if let payload {
            byteCount = Int(payload.totalSizeBytes)
            nextOffset = payload.nextOffset
            hasMoreText = !payload.eof
            let text = String(data: Data(payload.content), encoding: .utf8)
                ?? String(decoding: payload.content, as: UTF8.self)
            let newChunk = EvidenceTextChunk(
                itemID: itemID,
                pageOffset: offset,
                chunkIndex: reset ? 0 : textChunks.count,
                text: text
            )
            if reset {
                textChunks = [newChunk]
            } else {
                textChunks.append(newChunk)
            }
            self.errorMessage = nil
            return
        }
        self.errorMessage = errorMessage ?? "未知错误"
    }

    func shouldLoadNextPage(itemID: String) -> Bool {
        currentItemID == itemID && hasMoreText && !isPaging && !isLoading
    }
}

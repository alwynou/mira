import Foundation
import Observation

/// Window-local geometry only; no message bodies or rendered documents are retained.
@MainActor
final class ConversationReadingStore {
    private var states: [UUID: ConversationReadingState] = [:]
    private let empty = ConversationReadingState()

    func state(for id: UUID?) -> ConversationReadingState {
        guard let id else { return empty }
        if let state = states[id] { return state }
        let state = ConversationReadingState()
        states[id] = state
        return state
    }
}

/// Retains reading intent when the transcript leaves the window's detail column.
@MainActor @Observable
final class ConversationReadingState {
    struct NativeAnchor {
        let id: String
        let offset: CGFloat
    }
    @ObservationIgnored var nativeAnchor: NativeAnchor?
    @ObservationIgnored var expandedThinkingIDs: Set<String> = []
    var scrollState = TranscriptScrollState()
    @ObservationIgnored private var isVisible = true
    @ObservationIgnored private(set) var hasSavedPosition = false
    @ObservationIgnored var visibleOffset: CGFloat = 0
    @ObservationIgnored private(set) var pendingRestoreOffset: CGFloat?
    struct RowMeasurement {
        let signature: Int
        let width: CGFloat
        let height: CGFloat
    }
    @ObservationIgnored var rowMeasurements: [String: RowMeasurement] = [:]
    @ObservationIgnored var measurementStyle: String?

    func prepareForDisplay() {
        pendingRestoreOffset = hasSavedPosition ? visibleOffset : nil
        isVisible = true
    }

    func completeRestoration() { pendingRestoreOffset = nil }

    func recordOffset(_ offset: CGFloat) {
        guard isVisible, pendingRestoreOffset == nil else { return }
        hasSavedPosition = true
        visibleOffset = offset
    }

    func userStartedScrolling() { pendingRestoreOffset = nil }

    func leave() {
        isVisible = false
        scrollState.userScrollChanged(isScrolling: false, isNearBottom: false)
    }
}

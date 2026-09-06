import SwiftUI

enum TranscriptScrollAnimation {
    /// Retarget a non-bouncing spring from its current position and velocity.
    /// Reduce Motion and initial history placement use an immediate transaction.
    @MainActor
    static func perform(animated: Bool, _ update: () -> Void) {
        withAnimation(animated ? .smooth(duration: 0.22, extraBounce: 0) : nil, update)
    }
}

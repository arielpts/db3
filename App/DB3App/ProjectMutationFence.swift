import Foundation
import Synchronization
import DB3Core

/// Synchronous invalidation at the UI boundary closes the gap before an actor
/// processes a changed source snapshot. No filesystem or database work here.
final class ProjectMutationFence: Sendable {
    private let version = Mutex<UInt64>(0)
    func current() -> UInt64 { version.withLock { $0 } }
    func invalidate() { version.withLock { $0 &+= 1 } }
    func validate(_ expected: UInt64) throws {
        guard current() == expected else { throw DatabaseError("Project metadata changed. Refresh and preview these edits again.") }
    }
}

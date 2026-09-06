import Foundation

public enum BeaconMemoryPolicy {
    public static func disposition(
        of record: BeaconMemoryRecord,
        at date: Date
    ) -> BeaconMemoryStatus {
        guard record.status != .deleted else { return .deleted }
        guard record.expiresAt > date else { return .expired }
        guard record.status == .active, record.reviewAt > date else { return .needsReview }
        return .active
    }

    public static func activeRecords(
        in snapshot: BeaconMemorySnapshot,
        at date: Date
    ) -> [BeaconMemoryRecord] {
        snapshot.records
            .filter { disposition(of: $0, at: date) == .active }
            .sorted {
                if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
                return $0.updatedAt > $1.updatedAt
            }
    }
}

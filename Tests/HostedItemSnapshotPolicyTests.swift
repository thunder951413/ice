import Foundation

@main
enum HostedItemSnapshotPolicyTests {
    struct Item: Equatable {
        let id: String
        let owner: Int
        let title: String
    }

    static func main() {
        let first = Item(id: "first", owner: 10, title: "Old")
        let second = Item(id: "second", owner: 10, title: "Second")
        let slow = Item(id: "slow", owner: 11, title: "Slow")
        let exited = Item(id: "exited", owner: 12, title: "Exited")
        let existing = Dictionary(uniqueKeysWithValues: [first, second, slow, exited].map { ($0.id, $0) })
        let updated = Item(id: "first", owner: 10, title: "Updated")
        func merge(scanned: Set<Int>, concealed: Set<Int> = []) -> [String: Item] {
            HostedItemSnapshotPolicy.merge(existing: existing, discovered: [updated], liveOwners: [10, 11], scannedOwners: scanned,
                                           id: { $0.id }, owner: { $0.owner }, preserveMissing: { concealed.contains($0.owner) })
        }
        let complete = merge(scanned: [10])
        expect(complete["second"] == nil, "a complete visible-owner scan must remove a deleted item")
        expect(complete["first"] == updated, "changed descriptors must replace old metadata")
        expect(complete["slow"] == slow, "an unscanned/failed owner must retain its descriptor")
        expect(complete["exited"] == nil, "exited owners must disappear regardless of scan coverage")
        expect(merge(scanned: [10], concealed: [10])["second"] == second, "native concealment must preserve absent items")
        expect(merge(scanned: [])["second"] == second, "partial scans cannot establish deletion")
        print("HostedItemSnapshotPolicyTests passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
}

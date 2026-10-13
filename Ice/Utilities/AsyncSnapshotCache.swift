//
//  AsyncSnapshotCache.swift
//  Ice
//

import Foundation

/// UI readers never wait for the loader. Concurrent refreshes share one load;
/// invalidation prevents its obsolete result from becoming a usable snapshot.
final class AsyncSnapshotCache<Value>: @unchecked Sendable {
    private struct Reply {
        let value: Value?
        let invalidated: Bool
    }

    private let lock = NSLock()
    private let lifetime: TimeInterval
    private var entry: (date: Date, value: Value)?
    private var lastAttempt = Date.distantPast
    private var generation = 0
    private var inFlight: UUID?
    private var waiters = [CheckedContinuation<Reply, Never>]()

    init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    func value(at date: Date = .now) -> Value? {
        lock.withLock {
            guard let entry, date.timeIntervalSince(entry.date) < lifetime else { return nil }
            return entry.value
        }
    }

    func invalidate() {
        lock.withLock {
            generation += 1
            entry = nil
            lastAttempt = .distantPast
        }
    }

    func requestRefresh(force: Bool = false, load: @escaping () async -> Value?) {
        enqueue(force: force, continuation: nil, load: load)
    }

    func refresh(force: Bool = false, load: @escaping () async -> Value?) async -> Value? {
        var needsFreshScan = force
        while !Task.isCancelled {
            let reply: Reply = await withCheckedContinuation {
                enqueue(force: needsFreshScan, continuation: $0, load: load)
            }
            guard !Task.isCancelled else { return nil }
            if !reply.invalidated { return reply.value }
            // A layout change can invalidate an in-flight read while an
            // activation waits. Join one replacement scan instead of losing
            // the user's first click or returning obsolete geometry.
            needsFreshScan = true
        }
        return nil
    }

    private func enqueue(
        force: Bool, continuation: CheckedContinuation<Reply, Never>?, load: @escaping () async -> Value?
    ) {
        lock.lock()
        if !force, let entry, Date.now.timeIntervalSince(entry.date) < lifetime {
            lock.unlock()
            continuation?.resume(returning: Reply(value: entry.value, invalidated: false))
            return
        }
        if inFlight != nil {
            if let continuation { waiters.append(continuation) }
            lock.unlock()
            return
        }
        // Failed reads are also coalesced, instead of retrying on every mouse move.
        if !force, Date.now.timeIntervalSince(lastAttempt) < lifetime {
            lock.unlock()
            continuation?.resume(returning: Reply(value: nil, invalidated: false))
            return
        }
        let token = UUID()
        let attempt = generation
        inFlight = token
        lastAttempt = .now
        if let continuation { waiters.append(continuation) }
        lock.unlock()
        Task { [self] in
            let value = await load()
            finish(token: token, generation: attempt, value: value)
        }
    }

    private func finish(token: UUID, generation attempt: Int, value: Value?) {
        lock.lock()
        guard inFlight == token else {
            lock.unlock()
            return
        }
        let currentValue = generation == attempt ? value : nil
        entry = currentValue.map { (date: .now, value: $0) }
        let completions = waiters
        waiters.removeAll()
        inFlight = nil
        let reply = Reply(value: currentValue, invalidated: generation != attempt)
        lock.unlock()
        completions.forEach { $0.resume(returning: reply) }
    }
}

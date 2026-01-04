//
//  AsyncSemaphore.swift
//  WhisperShortcut
//
//  Actor-based semaphore for limiting concurrent async operations.
//

import Foundation

/// A thread-safe semaphore for limiting concurrent async operations.
/// Used to throttle parallel API calls during chunked transcription.
actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Initialize with the maximum number of concurrent operations allowed.
    /// - Parameter value: Maximum concurrent operations (e.g., 3 for API calls)
    init(value: Int) {
        self.value = max(1, value)
    }

    /// Wait to acquire a permit. Suspends if all permits are taken.
    func wait() async {
        if value > 0 {
            value -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    /// Release a permit, allowing a waiting operation to proceed.
    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            value += 1
        }
    }

    /// Current number of available permits.
    var availablePermits: Int {
        return value
    }

    /// Number of operations waiting for a permit.
    var waitingCount: Int {
        return waiters.count
    }
}

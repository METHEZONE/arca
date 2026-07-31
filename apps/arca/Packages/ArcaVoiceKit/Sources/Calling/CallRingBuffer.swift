import Foundation
import Synchronization

/// Single-producer, single-consumer float ring buffer.
///
/// Exists because the audio render thread must never block. The decode side
/// writes, `AVAudioSourceNode`'s render block reads, and neither takes a lock —
/// a contended lock on the render thread is exactly how you get the periodic
/// clicks that make a call sound cheap.
public final class CallRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    public init(capacity: Int) {
        // One slot stays empty so full and empty are distinguishable.
        self.capacity = capacity + 1
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: self.capacity)
        self.storage.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    public var availableToRead: Int {
        let write = writeIndex.load(ordering: .acquiring)
        let read = readIndex.load(ordering: .relaxed)
        return write >= read ? write - read : capacity - read + write
    }

    public var availableToWrite: Int {
        capacity - 1 - availableToRead
    }

    /// Producer side. Drops the whole chunk if it will not fit — partial writes
    /// would desynchronise the frame boundaries.
    @discardableResult
    public func write(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
        guard count <= availableToWrite else { return false }
        var index = writeIndex.load(ordering: .relaxed)
        for offset in 0..<count {
            storage[index] = samples[offset]
            index += 1
            if index == capacity { index = 0 }
        }
        writeIndex.store(index, ordering: .releasing)
        return true
    }

    /// Consumer side. Fills whatever it can and zero-pads the rest, so an underrun
    /// produces silence for that slice instead of stale audio.
    public func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let ready = min(count, availableToRead)
        var index = readIndex.load(ordering: .relaxed)
        for offset in 0..<ready {
            destination[offset] = storage[index]
            index += 1
            if index == capacity { index = 0 }
        }
        readIndex.store(index, ordering: .releasing)
        if ready < count {
            for offset in ready..<count { destination[offset] = 0 }
        }
        return ready
    }

    public func reset() {
        readIndex.store(0, ordering: .relaxed)
        writeIndex.store(0, ordering: .relaxed)
    }
}

import CadenceCore
import Dispatch
import Foundation
import Observation

/// Today's state for the dot and the Pocket, published on the main actor.
///
/// `reload()` asks for a fresh read. The read runs on a background queue, so the main thread never waits on
/// the disk, and requests made while one is running collapse into one more read after it: a burst of calls
/// is at most two reads, and the last state published is always read after the last request. A failed read
/// replaces the state with the failure, so old numbers never pass for current ones.
@MainActor @Observable
public final class DayModel {
    public private(set) var load: DayLoad = .loading

    @ObservationIgnored private let loader: any DayLoading
    @ObservationIgnored private let queue = DispatchQueue(label: "in.ashwingopalsamy.cadence.day-model", qos: .userInitiated)
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var requestedAgain = false

    public init(loader: any DayLoading) {
        self.loader = loader
    }

    /// The day, or nil while nothing has been read and after a failed read.
    public var state: DayState? {
        if case .loaded(let state) = load { return state }
        return nil
    }

    /// Why the store could not be read, or nil.
    public var failure: StoreFailure? {
        if case .failed(let failure) = load { return failure }
        return nil
    }

    /// Reads the store again. Returns at once.
    public func reload() {
        if reading {
            requestedAgain = true
            return
        }
        reading = true
        Task { await publish() }
    }

    private func publish() async {
        repeat {
            requestedAgain = false
            load = await read()
        } while requestedAgain
        reading = false
    }

    private func read() async -> DayLoad {
        let loader = loader
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: loader.load()) }
        }
    }
}

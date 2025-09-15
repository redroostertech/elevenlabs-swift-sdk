import Foundation
import LiveKit

/// **ConnectionManager**
///
/// A small façade around `LiveKit.Room` that emits **exactly one**
/// *agent‑ready* signal at the precise moment the remote agent is
/// reachable **and** at least one of its audio tracks is subscribed.
///
/// ▶︎ *Never too early*: we wait for both the participant *and* its track subscription.
/// ▶︎ *Never too late*: a short, configurable grace‑timeout prevents
///   indefinite waiting on networks where track subscription events can
///   be lost or delayed.
///
/// After the ready event fires you can safely send client‑initiation
/// metadata—​the remote side will be present and able to receive it.
@MainActor
final class ConnectionManager {
    // MARK: – Public callbacks

    /// Fired **once** when the remote agent is considered ready.
    var onAgentReady: (() -> Void)?

    /// Fired when all remote participants have left or the room disconnects.
    var onAgentDisconnected: (() -> Void)?
    
    /// Fired when the WebRTC connection is established (local network permission resolved).
    /// This happens before the agent is ready and can be used to delay agent launch.
    var onConnectionEstablished: (() -> Void)?

    // MARK: – Public state accessors

    private(set) var room: Room?

    // MARK: – Private

    private var readyDelegate: ReadyDelegate?

    // MARK: – Lifecycle

    /// Establish a LiveKit connection.
    ///
    /// - Parameters:
    ///   - details: Token‑service credentials (URL + participant token).
    ///   - enableMic: Whether to enable the local microphone immediately.
    ///   - graceTimeout: Fallback (in seconds) before we assume the agent is
    ///     ready even if no audio‑track subscription event is observed.
    func connect(
        details: TokenService.ConnectionDetails,
        enableMic: Bool,
        graceTimeout: TimeInterval = 0.5 // Reduced to 500ms based on test results showing consistent timeouts
    ) async throws {
        let room = Room()
        self.room = room

        // Delegate encapsulates all readiness logic.
        let rd = ReadyDelegate(
            graceTimeout: graceTimeout,
            onReady: { [weak self] in
                print("[ConnectionManager-Timing] Ready delegate fired onReady callback")
                self?.onAgentReady?()
            },
            onDisconnected: { [weak self] in self?.onAgentDisconnected?() },
            onConnectionEstablished: { [weak self] in self?.onConnectionEstablished?() }
        )
        readyDelegate = rd
        room.add(delegate: rd)

        let connectStart = Date()
        try await room.connect(url: details.serverUrl,
                               token: details.participantToken)
        print("[ConnectionManager-Timing] LiveKit room.connect completed in \(Date().timeIntervalSince(connectStart))s")

        if enableMic {
            // Await microphone enabling to ensure it's ready before proceeding
            do {
                try await room.localParticipant.setMicrophone(enabled: true)
                print("[ConnectionManager] Microphone enabled successfully")
            } catch {
                print("[ConnectionManager] Failed to enable microphone: \(error)")
                // Don't throw - microphone issues shouldn't prevent connection
            }
        }
    }

    /// Disconnect and tear down.
    func disconnect() async {
        await room?.disconnect()
        room = nil
        readyDelegate = nil
    }

    /// Convenience helper returning a typed `AsyncStream` for incoming
    /// data‑channel messages.
    func dataEventsStream() -> AsyncStream<Data> {
        guard let room else { return AsyncStream { $0.finish() } }

        return AsyncStream { continuation in
            room.add(delegate: DataChannelDelegate(continuation: continuation))
            continuation.onTermination = { _ in /* no‑op */ }
        }
    }
}

// MARK: – Ready‑detection delegate

private extension ConnectionManager {
    /// Internal delegate that guards the *agent‑ready* handshake.
    final class ReadyDelegate: RoomDelegate, @unchecked Sendable {
        // MARK: – FSM

        private enum Stage { case idle, waitingForSubscription, ready }
        private var stage: Stage = .idle

        // MARK: – Timing

        private let graceTimeout: TimeInterval
        private var timeoutTask: Task<Void, Never>?
        private var pollingTask: Task<Void, Never>?

        // MARK: – Callbacks

        private let onReady: () -> Void
        private let onDisconnected: () -> Void
        private let onConnectionEstablished: () -> Void

        // MARK: – Init

        init(graceTimeout: TimeInterval,
             onReady: @escaping () -> Void,
             onDisconnected: @escaping () -> Void,
             onConnectionEstablished: @escaping () -> Void)
        {
            self.graceTimeout = graceTimeout
            self.onReady = onReady
            self.onDisconnected = onDisconnected
            self.onConnectionEstablished = onConnectionEstablished
        }

        // MARK: – RoomDelegate

        func roomDidConnect(_ room: Room) {
            // Notify that connection is established (local network permission resolved)
            Task { @MainActor in
                onConnectionEstablished()
            }
            
            guard stage == .idle else { return }

            if !room.remoteParticipants.isEmpty {
                // Check if we can go ready immediately (fast path)
                var foundReadyAgent = false
                for participant in room.remoteParticipants.values {
                    if hasSubscribedAudioTrack(participant) {
                        markReady()
                        foundReadyAgent = true
                        break
                    }
                }

                // Only wait if we didn't find a ready agent
                if !foundReadyAgent {
                    stage = .waitingForSubscription
                    startTimeout()
                    // Start aggressive polling for audio track subscription
                    startAudioTrackSubscriptionPolling(room: room)
                }
            }
        }

        func room(_ room: Room, participantDidConnect _: RemoteParticipant) {
            stage = .waitingForSubscription
            startTimeout()
            evaluateExistingSubscriptions(in: room)
            // Start aggressive polling for audio track subscription
            startAudioTrackSubscriptionPolling(room: room)
        }

        func room(_: Room,
                  participant _: RemoteParticipant,
                  didSubscribeTrack publication: RemoteTrackPublication)
        {
            guard stage == .waitingForSubscription else { return }
            if publication.kind == .audio {
                print("[ReadyDelegate-Timing] Audio track subscribed - marking ready!")
                markReady()
            }
        }

        func room(_ room: Room,
                  participantDidDisconnect _: RemoteParticipant)
        {
            guard room.remoteParticipants.isEmpty else { return }
            reset()
            Task { @MainActor in
                onDisconnected()
            }
        }

        func room(_: Room, didUpdateConnectionState _: ConnectionState, from _: ConnectionState) { /* unused */ }

        // MARK: – Private helpers

        private func evaluateExistingSubscriptions(in room: Room) {
            for participant in room.remoteParticipants.values {
                // Check for subscribed tracks instead of published ones
                if hasSubscribedAudioTrack(participant) {
                    markReady(); return
                }
            }
            print("[ReadyDelegate-Timing] No subscribed audio tracks found yet, waiting...")
        }

        private func hasSubscribedAudioTrack(_ participant: RemoteParticipant) -> Bool {
            return participant.audioTracks.contains { publication in
                publication.isSubscribed && publication.track != nil
            }
        }

        private func markReady() {
            print("[ReadyDelegate-Timing] Marking ready!")
            guard stage != .ready else { return }
            stage = .ready
            cancelTimeout()
            cancelPolling() // Stop polling when ready
            Task { @MainActor in
                onReady()
            }
        }

        private func startTimeout() {
            print("[ReadyDelegate-Timing] Starting grace timeout of \(graceTimeout)s")
            timeoutTask = Task { [graceTimeout] in
                try? await Task.sleep(nanoseconds: UInt64(graceTimeout * 1_000_000_000))
                if !Task.isCancelled, stage == .waitingForSubscription {
                    print("[ReadyDelegate-Timing] Grace timeout reached! Marking ready anyway.")
                    markReady() // proceed after grace period
                }
            }
        }

        private func cancelTimeout() {
            timeoutTask?.cancel()
            timeoutTask = nil
        }

        private func startAudioTrackSubscriptionPolling(room: Room) {
            cancelPolling()
            print("[ReadyDelegate-Timing] Starting aggressive audio track subscription polling...")
            pollingTask = Task {
                // Poll every 50ms for up to 500ms (10 attempts)
                for attempt in 1 ... 10 {
                    guard !Task.isCancelled, stage == .waitingForSubscription else { return }

                    for participant in room.remoteParticipants.values {
                        if hasSubscribedAudioTrack(participant) {
                            print("[ReadyDelegate-Timing] Polling detected subscribed audio track on attempt \(attempt)!")
                            markReady()
                            return
                        }
                    }

                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                }
                print("[ReadyDelegate-Timing] Audio track subscription polling completed without finding subscribed track")
            }
        }

        private func cancelPolling() {
            pollingTask?.cancel()
            pollingTask = nil
        }

        private func reset() {
            cancelTimeout()
            cancelPolling()
            stage = .idle
        }
    }
}

// MARK: – Data‑channel delegate

private final class DataChannelDelegate: RoomDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation

    init(continuation: AsyncStream<Data>.Continuation) {
        self.continuation = continuation
    }

    // MARK: – Delegate

    nonisolated func room(_: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic _: String) {
        // Only process messages from the agent
        guard participant != nil else {
            print("[DataChannelReceiver] Received data but no participant, ignoring")
            return
        }

        continuation.yield(data)
    }

    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from previousState: ConnectionState) {
        print("DataChannelDelegate: Connection state changed from \(previousState) to \(connectionState)")
        print("DataChannelDelegate: Remote participants count: \(room.remoteParticipants.count)")

        if connectionState == .disconnected {
            continuation.finish()
        }
    }

    nonisolated func room(_: Room, participantDidConnect participant: RemoteParticipant) {
        print("DataChannelDelegate: Remote participant \(String(describing: participant.identity)) connected")
    }

    nonisolated func room(_: Room, participantDidDisconnect participant: RemoteParticipant) {
        print("DataChannelDelegate: Remote participant \(String(describing: participant.identity)) disconnected")
    }
}

// MARK: – Convenience error extension

extension ConversationError {
    static let notImplemented = ConversationError.authenticationFailed("Not implemented yet")
}

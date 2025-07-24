@testable import ElevenLabs
import Foundation
import LiveKit

final class MockConnectionManager {
    var shouldFailConnection = false
    var mockRoom: Room?

    private(set) var connectCallCount = 0
    private(set) var disconnectCallCount = 0
    private(set) var lastConnectionDetails: TokenService.ConnectionDetails?

    func connect(details: TokenService.ConnectionDetails, enableMic _: Bool) async throws {
        connectCallCount += 1
        lastConnectionDetails = details

        if shouldFailConnection {
            throw ConversationError.connectionFailed("Mock connection failed")
        }

        mockRoom = Room()
    }

    func disconnect() async {
        disconnectCallCount += 1
        mockRoom = nil
    }

    var room: Room? {
        mockRoom
    }

    func dataEventsStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

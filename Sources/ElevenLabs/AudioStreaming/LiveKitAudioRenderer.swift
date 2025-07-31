//
//  LiveKitAudioRenderer.swift
//  ElevenLabs
//
//  LiveKit audio renderer implementation for capturing audio frames
//

import Foundation
import LiveKit
import AVFoundation
import Combine

// MARK: - Updated Audio Streaming Implementation

public extension Conversation {
    /// Internal actor to manage audio renderers
    actor AudioStreamManager {
        private var userRenderer: AudioFrameCapture?
        private var agentRenderer: AudioFrameCapture?
        private var userContinuation: AsyncStream<AudioFrameData>.Continuation?
        private var agentContinuation: AsyncStream<AudioFrameData>.Continuation?
        
        func setupUserStream(track: LocalAudioTrack) -> AsyncStream<AudioFrameData> {
            AsyncStream { continuation in
                self.userContinuation = continuation
                
                let renderer = AudioFrameCapture(source: .user) { frame in
                    continuation.yield(frame)
                }
                
                self.userRenderer = renderer
                track.add(audioRenderer: renderer)
                
                continuation.onTermination = { [weak self] _ in
                    Task { [weak self] in
                        await self?.cleanupUserStream(track: track)
                    }
                }
            }
        }
        
        func setupAgentStream(track: RemoteAudioTrack) -> AsyncStream<AudioFrameData> {
            AsyncStream { continuation in
                self.agentContinuation = continuation
                
                let renderer = AudioFrameCapture(source: .agent) { frame in
                    continuation.yield(frame)
                }
                
                self.agentRenderer = renderer
                track.add(audioRenderer: renderer)
                
                continuation.onTermination = { [weak self] _ in
                    Task { [weak self] in
                        await self?.cleanupAgentStream(track: track)
                    }
                }
            }
        }
        
        private func cleanupUserStream(track: LocalAudioTrack) {
            if let renderer = userRenderer {
                track.remove(audioRenderer: renderer)
                userRenderer = nil
            }
            userContinuation?.finish()
            userContinuation = nil
        }
        
        private func cleanupAgentStream(track: RemoteAudioTrack) {
            if let renderer = agentRenderer {
                track.remove(audioRenderer: renderer)
                agentRenderer = nil
            }
            agentContinuation?.finish()
            agentContinuation = nil
        }
        
        func cleanup(userTrack: LocalAudioTrack?, agentTrack: RemoteAudioTrack?) {
            if let track = userTrack {
                cleanupUserStream(track: track)
            }
            if let track = agentTrack {
                cleanupAgentStream(track: track)
            }
        }
    }
    
    /// Create a properly configured user audio stream with LiveKit audio renderer
    func createUserAudioStream() -> AsyncStream<AudioFrameData>? {
        guard let track = inputTrack else { return nil }
        
        let manager = AudioStreamManager()
        
        return AsyncStream { continuation in
            Task {
                // Setup the stream with the manager
                let innerStream = await manager.setupUserStream(track: track)
                
                // Forward frames from inner stream
                for await frame in innerStream {
                    guard state.isActive else {
                        continuation.finish()
                        break
                    }
                    continuation.yield(frame)
                }
                
                // Cleanup when done
                await manager.cleanup(userTrack: track, agentTrack: nil)
                continuation.finish()
            }
        }
    }
    
    /// Create a properly configured agent audio stream with LiveKit audio renderer
    func createAgentAudioStream() -> AsyncStream<AudioFrameData>? {
        guard let track = agentAudioTrack else { return nil }
        
        let manager = AudioStreamManager()
        
        return AsyncStream { continuation in
            Task {
                // Setup the stream with the manager
                let innerStream = await manager.setupAgentStream(track: track)
                
                // Forward frames from inner stream
                for await frame in innerStream {
                    guard state.isActive else {
                        continuation.finish()
                        break
                    }
                    continuation.yield(frame)
                }
                
                // Cleanup when done
                await manager.cleanup(userTrack: nil, agentTrack: track)
                continuation.finish()
            }
        }
    }
}

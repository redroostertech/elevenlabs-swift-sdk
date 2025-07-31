//
//  AudioConverter.swift
//  ElevenLabs
//
//  Audio format conversion and resampling utilities
//

import Foundation
import AVFoundation
import AudioToolbox
import Accelerate

// MARK: - Protocols (Interface Segregation)

/// Protocol for audio format conversion
public protocol AudioFormatConverting {
    func convert(audioData: Data, from inputFormat: AudioFormat, to outputFormat: AudioFormat) throws -> Data
}

/// Protocol for audio resampling
public protocol AudioResampling {
    func resample(audioData: Data, from inputRate: UInt32, to outputRate: UInt32) throws -> Data
}

/// Protocol for channel mixing
public protocol AudioChannelMixing {
    func mixToMono(audioData: Data, channels: UInt32, samplesPerChannel: UInt32) throws -> Data
}

// MARK: - Value Objects

/// Represents audio format specifications
public struct AudioFormat: Equatable, Sendable {
    public let sampleRate: UInt32
    public let channels: UInt32
    public let bitsPerSample: UInt32
    
    public init(sampleRate: UInt32, channels: UInt32, bitsPerSample: UInt32 = 16) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitsPerSample = bitsPerSample
    }
    
    /// Common format for transcription services
    public static let transcriptionFormat = AudioFormat(sampleRate: 16000, channels: 1, bitsPerSample: 16)
}

// MARK: - Error Types

/// Errors that can occur during audio conversion
public enum AudioConversionError: LocalizedError {
    case invalidFormat
    case conversionFailed(String)
    case unsupportedChannelCount(UInt32)
    
    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid audio format"
        case .conversionFailed(let reason):
            return "Audio conversion failed: \(reason)"
        case .unsupportedChannelCount(let count):
            return "Unsupported channel count: \(count)"
        }
    }
}

// MARK: - Main Audio Converter (Single Responsibility)

/// Main audio converter that coordinates format conversion
public final class AudioConverter {
    
    private let formatConverter: AudioFormatConverting
    private let resampler: AudioResampling
    private let channelMixer: AudioChannelMixing
    
    /// Initialize with default implementations
    public convenience init() {
        self.init(
            formatConverter: AVAudioFormatConverter(),
            resampler: VDSPResampler(),
            channelMixer: SimpleChannelMixer()
        )
    }
    
    /// Initialize with custom implementations (Dependency Injection)
    public init(
        formatConverter: AudioFormatConverting,
        resampler: AudioResampling,
        channelMixer: AudioChannelMixing
    ) {
        self.formatConverter = formatConverter
        self.resampler = resampler
        self.channelMixer = channelMixer
    }
    
    /// Convert audio data to a specific format
    public func convert(
        audioData: Data,
        from inputFormat: AudioFormat,
        to outputFormat: AudioFormat
    ) throws -> Data {
        // If already in the correct format, return as-is
        if inputFormat == outputFormat {
            return audioData
        }
        
        var workingData = audioData
        
        // Step 1: Mix channels if needed
        if inputFormat.channels != outputFormat.channels && outputFormat.channels == 1 {
            let samplesPerChannel = audioData.count / (Int(inputFormat.channels) * Int(inputFormat.bitsPerSample / 8))
            workingData = try channelMixer.mixToMono(
                audioData: workingData,
                channels: inputFormat.channels,
                samplesPerChannel: UInt32(samplesPerChannel)
            )
        }
        
        // Step 2: Resample if needed
        if inputFormat.sampleRate != outputFormat.sampleRate {
            workingData = try resampler.resample(
                audioData: workingData,
                from: inputFormat.sampleRate,
                to: outputFormat.sampleRate
            )
        }
        
        return workingData
    }
}

// MARK: - Concrete Implementations

/// AVAudioConverter-based format converter
public final class AVAudioFormatConverter: AudioFormatConverting {
    public func convert(audioData: Data, from inputFormat: AudioFormat, to outputFormat: AudioFormat) throws -> Data {
        // Create AVAudioFormat instances
        guard let avInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(inputFormat.sampleRate),
            channels: inputFormat.channels,
            interleaved: true
        ) else {
            throw AudioConversionError.invalidFormat
        }
        
        guard let avOutputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(outputFormat.sampleRate),
            channels: outputFormat.channels,
            interleaved: true
        ) else {
            throw AudioConversionError.invalidFormat
        }
        
        guard let converter = AVAudioConverter(from: avInputFormat, to: avOutputFormat) else {
            throw AudioConversionError.conversionFailed("Failed to create AVAudioConverter")
        }
        
        // Calculate frame counts
        let bytesPerFrame = avInputFormat.streamDescription.pointee.mBytesPerFrame
        let inputFrameCount = UInt32(audioData.count) / bytesPerFrame
        let outputFrameCount = UInt32(Double(inputFrameCount) * Double(outputFormat.sampleRate) / Double(inputFormat.sampleRate))
        
        // Create buffers
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: avInputFormat, frameCapacity: inputFrameCount) else {
            throw AudioConversionError.conversionFailed("Failed to create input buffer")
        }
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: avOutputFormat, frameCapacity: outputFrameCount) else {
            throw AudioConversionError.conversionFailed("Failed to create output buffer")
        }
        
        // Copy data to input buffer
        inputBuffer.frameLength = inputFrameCount
        audioData.withUnsafeBytes { bytes in
            memcpy(inputBuffer.audioBufferList.pointee.mBuffers.mData, bytes.baseAddress, audioData.count)
        }
        
        // Perform conversion
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        
        if let error = error {
            throw AudioConversionError.conversionFailed(error.localizedDescription)
        }
        
        // Extract output data
        let outputBytes = Int(outputBuffer.frameLength * avOutputFormat.streamDescription.pointee.mBytesPerFrame)
        return Data(bytes: outputBuffer.audioBufferList.pointee.mBuffers.mData!, count: outputBytes)
    }
}

/// vDSP-based resampler for efficient mono audio resampling
public final class VDSPResampler: AudioResampling {
    public func resample(audioData: Data, from inputRate: UInt32, to outputRate: UInt32) throws -> Data {
        if inputRate == outputRate {
            return audioData
        }
        
        // Convert Int16 samples to Float for processing
        let sampleCount = audioData.count / MemoryLayout<Int16>.size
        var floatSamples = [Float](repeating: 0, count: sampleCount)
        
        audioData.withUnsafeBytes { bytes in
            let int16Pointer = bytes.bindMemory(to: Int16.self)
            
            // Convert Int16 to Float and normalize
            var scale: Float = 1.0 / 32768.0
            vDSP_vflt16(int16Pointer.baseAddress!, 1, &floatSamples, 1, vDSP_Length(sampleCount))
            vDSP_vsmul(floatSamples, 1, &scale, &floatSamples, 1, vDSP_Length(sampleCount))
        }
        
        // Calculate output sample count
        let outputSampleCount = Int(Double(sampleCount) * Double(outputRate) / Double(inputRate))
        var outputSamples = [Float](repeating: 0, count: outputSampleCount)
        
        // Linear interpolation resampling
        let step = Double(inputRate) / Double(outputRate)
        
        for i in 0..<outputSampleCount {
            let sourceIndex = Double(i) * step
            let index = Int(sourceIndex)
            let fraction = Float(sourceIndex - Double(index))
            
            if index + 1 < sampleCount {
                outputSamples[i] = floatSamples[index] * (1.0 - fraction) + floatSamples[index + 1] * fraction
            } else if index < sampleCount {
                outputSamples[i] = floatSamples[index]
            }
        }
        
        // Convert back to Int16
        var int16Samples = [Int16](repeating: 0, count: outputSampleCount)
        var scale: Float = 32767.0
        vDSP_vsmul(outputSamples, 1, &scale, &outputSamples, 1, vDSP_Length(outputSampleCount))
        vDSP_vfix16(outputSamples, 1, &int16Samples, 1, vDSP_Length(outputSampleCount))
        
        return Data(bytes: int16Samples, count: int16Samples.count * MemoryLayout<Int16>.size)
    }
}

/// Simple channel mixer for stereo to mono conversion
public final class SimpleChannelMixer: AudioChannelMixing {
    public func mixToMono(audioData: Data, channels: UInt32, samplesPerChannel: UInt32) throws -> Data {
        if channels == 1 {
            return audioData
        }
        
        if channels == 2 {
            // Stereo to mono by averaging channels
            var monoSamples = [Int16](repeating: 0, count: Int(samplesPerChannel))
            
            audioData.withUnsafeBytes { bytes in
                let int16Pointer = bytes.bindMemory(to: Int16.self)
                
                for i in 0..<Int(samplesPerChannel) {
                    let left = Int32(int16Pointer[i * 2])
                    let right = Int32(int16Pointer[i * 2 + 1])
                    monoSamples[i] = Int16((left + right) / 2)
                }
            }
            
            return Data(bytes: monoSamples, count: monoSamples.count * MemoryLayout<Int16>.size)
        }
        
        throw AudioConversionError.unsupportedChannelCount(channels)
    }
}

// MARK: - AudioFrameData Extension

public extension AudioFrameData {
    /// Convert this audio frame to a specific format for transcription
    /// - Parameters:
    ///   - targetFormat: Target audio format (default: 16kHz mono)
    /// - Returns: Converted audio data
    public func convert(to targetFormat: AudioFormat = .transcriptionFormat) throws -> Data {
        let currentFormat = AudioFormat(
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: 16 // Assuming 16-bit PCM
        )
        
        let converter = AudioConverter()
        return try converter.convert(
            audioData: data,
            from: currentFormat,
            to: targetFormat
        )
    }
}

//
//  RemoteMicAUHALCapture.swift
//  FluidVoice Studio
//
//  Full-rate HAL input that shares the device with local dictation.
//  AVFoundation as a second client starved this path to about 0.13× realtime;
//  an input-only AUHAL unit does not.
//

import AudioToolbox
import CoreAudio
import Foundation

final nonisolated class RemoteMicAUHALCapture: @unchecked Sendable {
    var onPCM: @Sendable (Data) -> Void = { _ in }
    var onFailure: @Sendable (String) -> Void = { _ in }

    private let ring = RemoteMicPCMRing(capacity: 48_000 * 4)
    private let drainQueue = DispatchQueue(label: "fluidvoice.studio.mic-share.drain")
    private let lock = NSLock()
    private var audioUnit: AudioUnit?
    private var scratch: UnsafeMutablePointer<Float>?
    private var pcmScratch: UnsafeMutablePointer<Int16>?
    private var bufferList: UnsafeMutablePointer<AudioBufferList>?
    private var drainTimer: DispatchSourceTimer?
    private var channels: UInt32 = 1
    private var running = false

    func start(deviceID: AudioDeviceID) {
        self.stop()
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            self.onFailure("The HAL audio unit is unavailable.")
            return
        }
        var created: AudioUnit?
        let status = AudioComponentInstanceNew(component, &created)
        guard status == noErr, let unit = created else {
            self.onFailure("The HAL audio unit could not be opened (\(status)).")
            return
        }

        var enable: UInt32 = 1
        var disable: UInt32 = 0
        guard self.setUInt32(enable, unit: unit, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, element: 1),
              self.setUInt32(disable, unit: unit, property: kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, element: 0)
        else {
            AudioComponentInstanceDispose(unit)
            self.onFailure("The microphone could not be opened for sharing.")
            return
        }
        var device = deviceID
        let deviceStatus = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard deviceStatus == noErr else {
            AudioComponentInstanceDispose(unit)
            self.onFailure("The selected microphone could not be selected for sharing (\(deviceStatus)).")
            return
        }

        var native = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let nativeStatus = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &native, &size)
        guard nativeStatus == noErr else {
            AudioComponentInstanceDispose(unit)
            self.onFailure("The microphone format could not be read (\(nativeStatus)).")
            return
        }
        let channelCount = max(native.mChannelsPerFrame, 1)
        var client = AudioStreamBasicDescription(
            mSampleRate: Float64(RemoteMicProtocol.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 4 * channelCount,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channelCount,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let formatStatus = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &client,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard formatStatus == noErr else {
            AudioComponentInstanceDispose(unit)
            self.onFailure("48 kHz capture could not be started (\(formatStatus)).")
            return
        }

        self.lock.lock()
        self.audioUnit = unit
        self.channels = channelCount
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: Int(channelCount) * 4_096)
        self.pcmScratch = UnsafeMutablePointer<Int16>.allocate(capacity: 4_096)
        self.bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        self.running = true
        self.lock.unlock()

        var callback = AURenderCallbackStruct(
            inputProc: remoteMicHALInput,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let callbackStatus = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard callbackStatus == noErr else {
            self.stop()
            self.onFailure("The capture callback could not be installed (\(callbackStatus)).")
            return
        }
        let initStatus = AudioUnitInitialize(unit)
        let startStatus = initStatus == noErr ? AudioOutputUnitStart(unit) : initStatus
        guard startStatus == noErr else {
            self.stop()
            self.onFailure("Microphone capture did not start (\(startStatus)).")
            return
        }
        self.startDrain()
    }

    func stop() {
        self.drainTimer?.cancel()
        self.drainTimer = nil
        self.lock.lock()
        self.running = false
        let unit = self.audioUnit
        self.audioUnit = nil
        self.lock.unlock()
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        self.lock.lock()
        let scratch = self.scratch
        let pcm = self.pcmScratch
        let list = self.bufferList
        self.scratch = nil
        self.pcmScratch = nil
        self.bufferList = nil
        self.lock.unlock()
        scratch?.deallocate()
        pcm?.deallocate()
        list?.deallocate()
    }

    func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        time: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) -> OSStatus {
        self.lock.lock()
        let unit = self.audioUnit
        let channels = self.channels
        let scratch = self.scratch
        let pcm = self.pcmScratch
        let list = self.bufferList
        self.lock.unlock()
        guard let unit, let scratch, let pcm, let list else { return noErr }
        let count = Int(frames)
        guard count > 0, count <= 4_096 else { return noErr }
        list.pointee.mNumberBuffers = 1
        list.pointee.mBuffers.mNumberChannels = channels
        list.pointee.mBuffers.mDataByteSize = frames * 4 * channels
        list.pointee.mBuffers.mData = UnsafeMutableRawPointer(scratch)
        let status = AudioUnitRender(unit, flags, time, 1, frames, list)
        guard status == noErr else { return status }
        let channelCount = Int(channels)
        for frame in 0..<count {
            var sum: Float = 0
            if channelCount <= 1 {
                sum = scratch[frame]
            } else {
                for channel in 0..<channelCount {
                    sum += scratch[frame * channelCount + channel]
                }
                sum /= Float(channelCount)
            }
            let clipped = min(1, max(-1, sum))
            pcm[frame] = Int16((clipped * 32_767).rounded())
        }
        self.ring.push(pcm, count: count)
        return noErr
    }

    private func startDrain() {
        let timer = DispatchSource.makeTimerSource(queue: self.drainQueue)
        timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5))
        let handler: @Sendable () -> Void = { [weak self] in
            self?.drainOnce()
        }
        timer.setEventHandler(handler: handler)
        timer.resume()
        self.drainTimer = timer
    }

    func drainOnce() {
        guard self.isRunning() else { return }
        if let data = self.ring.pop(frames: 960, dropAbove: 4_800) {
            self.onPCM(data)
        }
    }

    private func isRunning() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.running
    }

    private func setUInt32(
        _ value: UInt32,
        unit: AudioUnit,
        property: AudioUnitPropertyID,
        scope: AudioUnitScope,
        element: AudioUnitElement
    ) -> Bool {
        var copy = value
        return AudioUnitSetProperty(unit, property, scope, element, &copy, UInt32(MemoryLayout<UInt32>.size)) == noErr
    }
}

private nonisolated func remoteMicHALInput(
    refCon: UnsafeMutableRawPointer,
    flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    time: UnsafePointer<AudioTimeStamp>,
    bus: UInt32,
    frames: UInt32,
    data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let capture = Unmanaged<RemoteMicAUHALCapture>.fromOpaque(refCon).takeUnretainedValue()
    return capture.render(flags: flags, time: time, frames: frames)
}

private final nonisolated class RemoteMicPCMRing: @unchecked Sendable {
    private let samples: UnsafeMutablePointer<Int16>
    private let capacity: Int
    private var writeIndex = 0
    private var readIndex = 0
    private let lock = NSLock()

    init(capacity: Int) {
        self.capacity = max(capacity, 4_096)
        self.samples = UnsafeMutablePointer<Int16>.allocate(capacity: self.capacity)
        self.samples.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        self.samples.deallocate()
    }

    func push(_ source: UnsafePointer<Int16>, count: Int) {
        self.lock.lock()
        defer { self.lock.unlock() }
        var remaining = count
        var pointer = source
        while remaining > 0 {
            var used = (self.writeIndex - self.readIndex + self.capacity) % self.capacity
            var free = self.capacity - used - 1
            if free == 0 {
                self.readIndex = (self.readIndex + remaining) % self.capacity
                used = (self.writeIndex - self.readIndex + self.capacity) % self.capacity
                free = self.capacity - used - 1
                if free == 0 { return }
            }
            let chunk = min(remaining, free, self.capacity - (self.writeIndex % self.capacity))
            (self.samples + (self.writeIndex % self.capacity)).update(from: pointer, count: chunk)
            self.writeIndex += chunk
            pointer += chunk
            remaining -= chunk
        }
    }

    func pop(frames: Int, dropAbove: Int) -> Data? {
        self.lock.lock()
        defer { self.lock.unlock() }
        var used = (self.writeIndex - self.readIndex + self.capacity) % self.capacity
        if used > dropAbove {
            self.readIndex = (self.writeIndex - frames + self.capacity) % self.capacity
            used = frames
        }
        guard used >= frames else { return nil }
        var data = Data(count: frames * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            guard let destination = raw.bindMemory(to: Int16.self).baseAddress else { return }
            var copied = 0
            while copied < frames {
                let chunk = min(frames - copied, self.capacity - (self.readIndex % self.capacity))
                (destination + copied).update(from: self.samples + (self.readIndex % self.capacity), count: chunk)
                self.readIndex += chunk
                copied += chunk
            }
        }
        return data
    }
}

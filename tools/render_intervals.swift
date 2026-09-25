import Foundation
import AVFoundation
import AudioToolbox

struct Voice {
    let notes: [UInt8]
    let channel: UInt8
    let velocity: UInt8
    let pan: UInt8
}

struct NoteEvent {
    let frame: AVAudioFramePosition
    let isNoteOn: Bool
    let note: UInt8
    let velocity: UInt8
    let channel: UInt8
}

enum RenderError: Error, CustomStringConvertible {
    case audioUnit(String)
    case render(String)

    var description: String {
        switch self {
        case .audioUnit(let message), .render(let message): return message
        }
    }
}

let sampleRate = 44_100.0
let maximumFrames: AVAudioFrameCount = 4_096
let openingSilence = 0.45
let closingTail = 3.5
let halfNoteBPM = 60.0
let wholeNoteSeconds = 120.0 / halfNoteBPM
let finalBreveMultiplier = 1.0
let articulation = 0.94
let churchOrganProgram: UInt8 = 19 // General MIDI: Church Organ (zero-based)

func makeDLSSynth() throws -> AVAudioUnitMIDIInstrument {
    let description = AudioComponentDescription(
        componentType: kAudioUnitType_MusicDevice,
        componentSubType: kAudioUnitSubType_DLSSynth,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    )

    let semaphore = DispatchSemaphore(value: 0)
    var result: AVAudioUnit?
    var resultError: Error?

    AVAudioUnit.instantiate(with: description, options: []) { unit, error in
        result = unit
        resultError = error
        semaphore.signal()
    }

    guard semaphore.wait(timeout: .now() + 15) == .success else {
        throw RenderError.audioUnit("DLSMusicDevice를 불러오는 데 시간이 너무 오래 걸렸습니다.")
    }
    if let resultError {
        throw RenderError.audioUnit("DLSMusicDevice 오류: \(resultError)")
    }
    guard let instrument = result as? AVAudioUnitMIDIInstrument else {
        throw RenderError.audioUnit("macOS 내장 DLSMusicDevice를 찾지 못했습니다.")
    }
    return instrument
}

func render(title: String, voices: [Voice], outputURL: URL) throws {
    guard let noteCount = voices.first?.notes.count, noteCount > 0,
          voices.allSatisfy({ $0.notes.count == noteCount }) else {
        throw RenderError.render("모든 성부의 음표 수가 같아야 합니다.")
    }

    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let engine = AVAudioEngine()
    let instrument = try makeDLSSynth()
    let reverb = AVAudioUnitReverb()
    reverb.loadFactoryPreset(.cathedral)
    reverb.wetDryMix = 16
    engine.attach(instrument)
    engine.attach(reverb)
    engine.connect(instrument, to: reverb, format: nil)
    engine.connect(reverb, to: engine.mainMixerNode, format: nil)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrames)
    try engine.start()

    for voice in voices {
        instrument.sendProgramChange(churchOrganProgram, onChannel: voice.channel)
        instrument.sendController(10, withValue: voice.pan, onChannel: voice.channel)
        instrument.sendController(7, withValue: 105, onChannel: voice.channel)
    }

    var events: [NoteEvent] = []
    var musicalTime = openingSilence
    for index in 0..<noteCount {
        let duration = wholeNoteSeconds * (index == noteCount - 1 ? finalBreveMultiplier : 1.0)
        for voice in voices {
            let note = voice.notes[index]
            let startFrame = AVAudioFramePosition((musicalTime * sampleRate).rounded())
            let stopFrame = AVAudioFramePosition(((musicalTime + duration * articulation) * sampleRate).rounded())
            events.append(NoteEvent(frame: startFrame, isNoteOn: true, note: note, velocity: voice.velocity, channel: voice.channel))
            events.append(NoteEvent(frame: stopFrame, isNoteOn: false, note: note, velocity: 0, channel: voice.channel))
        }
        musicalTime += duration
    }

    events.sort {
        if $0.frame != $1.frame { return $0.frame < $1.frame }
        if $0.isNoteOn != $1.isNoteOn { return !$0.isNoteOn }
        return $0.channel < $1.channel
    }

    let totalFrames = AVAudioFramePosition(((musicalTime + closingTail) * sampleRate).rounded())
    let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maximumFrames)!
    var eventIndex = 0

    while engine.manualRenderingSampleTime < totalFrames {
        let currentFrame = engine.manualRenderingSampleTime

        while eventIndex < events.count && events[eventIndex].frame <= currentFrame {
            let event = events[eventIndex]
            if event.isNoteOn {
                instrument.startNote(event.note, withVelocity: event.velocity, onChannel: event.channel)
            } else {
                instrument.stopNote(event.note, onChannel: event.channel)
            }
            eventIndex += 1
        }

        let nextEventFrame = eventIndex < events.count ? events[eventIndex].frame : totalFrames
        let framesUntilBoundary = max(1, nextEventFrame - currentFrame)
        let remainingFrames = max(1, totalFrames - currentFrame)
        let framesToRender = AVAudioFrameCount(min(AVAudioFramePosition(maximumFrames), framesUntilBoundary, remainingFrames))

        let status = try engine.renderOffline(framesToRender, to: buffer)
        switch status {
        case .success:
            try file.write(from: buffer)
        case .insufficientDataFromInputNode:
            continue
        case .cannotDoInCurrentContext:
            continue
        case .error:
            throw RenderError.render("오프라인 렌더링 중 오류가 발생했습니다.")
        @unknown default:
            throw RenderError.render("알 수 없는 오프라인 렌더링 상태입니다.")
        }
    }

    engine.stop()
    print("완료: \(title) → \(outputURL.path)")
}

guard CommandLine.arguments.count == 2 else {
    fputs("사용법: render_fux_pipe_organ_audio.swift OUTPUT_DIRECTORY\n", stderr)
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)


// Whole notes: B3–F4, B-flat3–F4, B3–F-sharp4.
// Independently read from Mann figures 9–10 and compared with existing LilyPond.
for (name, lower, upper) in [("fig09", UInt8(59), UInt8(65)), ("fig10_flat", UInt8(58), UInt8(65)), ("fig10_sharp", UInt8(59), UInt8(66))] {
    try render(title: name, voices: [Voice(notes: [lower], channel: 0, velocity: 80, pan: 56), Voice(notes: [upper], channel: 1, velocity: 80, pan: 72)], outputURL: outputDirectory.appendingPathComponent(name + ".wav"))
}

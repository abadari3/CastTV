import AVFoundation
import CastTVShared
import Foundation
import UIKit

enum CapabilityDetector {

    static func detect() -> CapabilitiesMessage {
        let display = detectDisplay()
        let audio = detectAudio()

        var model = "Unknown"
        var systemVersion = "Unknown"

        #if os(tvOS)
        model = machineIdentifier()
        systemVersion = UIDevice.current.systemVersion
        #endif

        let name = UIDevice.current.name

        return CapabilitiesMessage(
            model: model,
            tvOS: systemVersion,
            name: name,
            display: display,
            audio: audio
        )
    }

    private static func detectDisplay() -> DisplayCapabilities {
        let screen = UIScreen.main
        let currentMode = screen.currentMode
        let resolution: String
        if let mode = currentMode {
            resolution = "\(Int(mode.size.width))x\(Int(mode.size.height))"
        } else {
            let bounds = screen.bounds
            let scale = screen.scale
            resolution = "\(Int(bounds.width * scale))x\(Int(bounds.height * scale))"
        }

        var availableModes: [String] = []
        #if os(tvOS)
        // availableModes may not be available on all tvOS versions
        if #available(tvOS 16.0, *) {
            // Use current mode as the only known mode
            if let mode = currentMode {
                availableModes = ["\(Int(mode.size.width))x\(Int(mode.size.height))"]
            }
        }
        #endif
        let maxRefreshRate = screen.maximumFramesPerSecond

        let gamut: String
        switch screen.traitCollection.displayGamut {
        case .P3: gamut = "P3"
        case .SRGB: gamut = "sRGB"
        default: gamut = "unknown"
        }

        var hdrModes: [String] = []
        let availableHDR = AVPlayer.availableHDRModes
        if availableHDR.contains(.hdr10) { hdrModes.append("hdr10") }
        if availableHDR.contains(.dolbyVision) { hdrModes.append("dolbyVision") }
        if availableHDR.contains(.hlg) { hdrModes.append("hlg") }

        return DisplayCapabilities(
            resolution: resolution,
            availableModes: availableModes,
            maxRefreshRate: maxRefreshRate,
            displayGamut: gamut,
            hdrModes: hdrModes
        )
    }

    private static func detectAudio() -> AudioCapabilities {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)

        let maxChannels = session.maximumOutputNumberOfChannels

        var outputType = "Unknown"
        let outputs = session.currentRoute.outputs
        if let first = outputs.first {
            outputType = first.portType.rawValue
        }

        // Check for Atmos support (E-AC-3 JOC)
        var atmosSupported = false
        // On tvOS, Atmos is available when outputting via HDMI to an Atmos-capable receiver
        // We approximate by checking if we have > 2 channels available
        if maxChannels > 2 {
            atmosSupported = true
        }

        var spatialAudioEnabled = false
        for output in outputs {
            if output.isSpatialAudioEnabled {
                spatialAudioEnabled = true
                break
            }
        }

        return AudioCapabilities(
            maxChannels: maxChannels,
            outputType: outputType,
            atmosSupported: atmosSupported,
            spatialAudioEnabled: spatialAudioEnabled
        )
    }

    private static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "Unknown"
            }
        }
        return machine
    }
}

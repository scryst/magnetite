import CoreAudio
import Foundation

/// System output volume, observed rather than intercepted.
///
/// The obvious way to know the volume changed is to tap the media keys, which
/// needs Accessibility. A CoreAudio property listener on the default output
/// device gives the same signal with **no permission at all**, and it also
/// catches changes made from Control Center, a Bluetooth remote, or another app
/// — which a key tap misses entirely. Strictly better, and it is why there is
/// no event tap here.
@MainActor
final class VolumeManager {

    private(set) var volume: Float = 0
    private(set) var isMuted = false

    /// Fires on a genuine user-visible change, not on our own initial read.
    var onChange: ((Float, Bool) -> Void)?

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    /// The block has to be kept: Core Audio matches registrations on
    /// (object, address, block), so without it there is no way to unregister.
    private var listeners: [(AudioObjectID,
                             AudioObjectPropertyAddress,
                             AudioObjectPropertyListenerBlock)] = []
    private var primed = false

    init() {
        attachToDefaultDevice()
        observeDefaultDeviceChanges()
    }

    // MARK: Device wiring

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func currentDefaultOutput() -> AudioObjectID {
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &Self.defaultOutputAddress, 0, nil, &size, &id)
        return status == noErr ? id : AudioObjectID(kAudioObjectUnknown)
    }

    private func observeDefaultDeviceChanges() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.attachToDefaultDevice() }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &Self.defaultOutputAddress, DispatchQueue.main, block)
    }

    private func attachToDefaultDevice() {
        removeListeners()
        deviceID = currentDefaultOutput()
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return
        }
        primed = false
        addListener(selector: kAudioDevicePropertyVolumeScalar)
        addListener(selector: kAudioDevicePropertyMute)
        readCurrent()
        primed = true
    }

    private func addListener(selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(deviceID, &address) else {
            // Some devices expose per-channel volume only.
            address.mElement = 1
            guard AudioObjectHasProperty(deviceID, &address) else { return }
            attach(address)
            return
        }
        attach(address)
    }

    private func attach(_ address: AudioObjectPropertyAddress) {
        var addr = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleChange() }
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &addr, DispatchQueue.main, block) == noErr {
            listeners.append((deviceID, address, block))
        }
    }

    /// Actually unregister.
    ///
    /// This used to drop the array on the floor, which does nothing to Core
    /// Audio: every listener stayed live and each output-device change stacked
    /// another set on top, so an afternoon of switching between speakers and
    /// headphones left dozens of callbacks all firing for one volume change.
    private func removeListeners() {
        for (id, address, block) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(id, &addr, DispatchQueue.main, block)
        }
        listeners.removeAll()
    }

    // MARK: Reads

    private func readScalar() -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)

        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
            return value
        }
        // Fall back to the mean of the stereo pair.
        var total: Float = 0
        var found = 0
        for channel in UInt32(1)...UInt32(2) {
            address.mElement = channel
            var v: Float = 0
            var s = UInt32(MemoryLayout<Float>.size)
            if AudioObjectHasProperty(deviceID, &address),
               AudioObjectGetPropertyData(deviceID, &address, 0, nil, &s, &v) == noErr {
                total += v
                found += 1
            }
        }
        return found > 0 ? total / Float(found) : nil
    }

    private func readMuted() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
            return value != 0
        }
        // The same per-channel fallback the listener registration and
        // `readScalar` already make — without it those devices fire the mute
        // listener, this read pins `isMuted` false, and `handleChange` eats the
        // event as a no-op: no HUD for the press, and the next volume HUD
        // renders unmuted while the device is muted. Muted if ANY channel is,
        // which is how a stereo pair's mute switch behaves.
        for channel in UInt32(1)...UInt32(2) {
            address.mElement = channel
            var v: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectHasProperty(deviceID, &address),
               AudioObjectGetPropertyData(deviceID, &address, 0, nil, &s, &v) == noErr,
               v != 0 {
                return true
            }
        }
        return false
    }

    private func readCurrent() {
        if let v = readScalar() { volume = v }
        isMuted = readMuted()
    }

    private func handleChange() {
        let previousVolume = volume
        let previousMute = isMuted
        readCurrent()
        guard primed else { return }
        // Ignore sub-perceptual jitter so we don't flash the HUD on noise.
        guard abs(volume - previousVolume) > 0.0005 || isMuted != previousMute else { return }
        onChange?(volume, isMuted)
    }
}

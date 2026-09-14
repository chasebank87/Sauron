import AVFoundation
import CoreAudio
import Foundation

/// Observes mic plug/unplug and default-input changes so recording can rebind live.
final class AudioInputDeviceWatcher: @unchecked Sendable {
    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "app.sauron.mic-watcher", qos: .utility)
    private var debounceTask: Task<Void, Never>?
    private var started = false
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var devicesListener: AudioObjectPropertyListenerBlock?

    func start() {
        queue.sync {
            guard !started else { return }
            started = true

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(handleAVCaptureChange(_:)),
                name: AVCaptureDevice.wasConnectedNotification,
                object: nil
            )
            center.addObserver(
                self,
                selector: #selector(handleAVCaptureChange(_:)),
                name: AVCaptureDevice.wasDisconnectedNotification,
                object: nil
            )

            installHardwareListeners()
        }
    }

    func stop() {
        queue.sync {
            guard started else { return }
            started = false
            debounceTask?.cancel()
            debounceTask = nil
            NotificationCenter.default.removeObserver(self)
            removeHardwareListeners()
        }
    }

    deinit {
        stop()
    }

    @objc private func handleAVCaptureChange(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice else {
            scheduleNotify()
            return
        }
        guard device.hasMediaType(.audio) else { return }
        scheduleNotify()
    }

    private func scheduleNotify() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }

    private func installHardwareListeners() {
        let notify: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleNotify()
        }
        defaultInputListener = notify
        devicesListener = notify

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            queue,
            notify
        )

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            queue,
            notify
        )
    }

    private func removeHardwareListeners() {
        if let defaultInputListener {
            var defaultAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultAddress,
                queue,
                defaultInputListener
            )
        }
        if let devicesListener {
            var devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                queue,
                devicesListener
            )
        }
        defaultInputListener = nil
        devicesListener = nil
    }
}

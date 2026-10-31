import Darwin
import Foundation

final class MainThreadWatchdog {
    static let shared = MainThreadWatchdog()

    private let lock = NSLock()
    private var lastHeartbeat = DispatchTime.now().uptimeNanoseconds
    private var heartbeatTimer: DispatchSourceTimer?
    private var monitorTimer: DispatchSourceTimer?

    private init() {}

    func start() {
        guard heartbeatTimer == nil else { return }

        let heartbeat = DispatchSource.makeTimerSource(queue: .main)
        heartbeat.schedule(deadline: .now() + 2, repeating: 2)
        heartbeat.setEventHandler { [weak self] in self?.recordHeartbeat() }
        heartbeatTimer = heartbeat
        heartbeat.resume()

        let monitor = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        monitor.schedule(deadline: .now() + 10, repeating: 5)
        monitor.setEventHandler { [weak self] in self?.checkHeartbeat() }
        monitorTimer = monitor
        monitor.resume()
    }

    private func recordHeartbeat() {
        lock.lock()
        lastHeartbeat = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    private func checkHeartbeat() {
        lock.lock()
        let elapsed = DispatchTime.now().uptimeNanoseconds - lastHeartbeat
        lock.unlock()
        guard elapsed > 45_000_000_000 else { return }

        NSLog("GDW Vault: el hilo principal dejó de responder; saliendo para permitir la recuperación automática")
        exit(70)
    }
}

import Foundation
import AppKit

/// The long-lived recording process behind `iris start`. It is controlled with signals:
/// INT or TERM finishes the recording, USR1 pauses it, USR2 resumes it.
@MainActor
public final class RecorderDaemon {
    private let store: SessionStore
    private let maxDuration: Double
    private let pid = getpid()
    private var recorder: Recorder?
    private var finishing = false
    private var sources: [DispatchSourceSignal] = []
    private var ticker: DispatchSourceTimer?

    /// Must be called on the main thread; never returns.
    public static func run(store: SessionStore, request: TargetRequest, name: String, fps: Int, maxDuration: Double,
                           wait: Double = 0) -> Never {
        // Leave the caller's session, so the recording outlives the shell command that began it.
        setsid()
        signal(SIGHUP, SIG_IGN)
        // ScreenCaptureKit needs a window server connection, which a bare tool lacks.
        let app = NSApplication.shared
        let daemon = RecorderDaemon(store: store, maxDuration: maxDuration)
        daemon.begin(request: request, name: name, fps: fps, wait: wait)
        app.run()
        exit(0)
    }

    private init(store: SessionStore, maxDuration: Double) {
        self.store = store
        self.maxDuration = maxDuration
    }

    private func report(_ status: String, error: String? = nil) {
        let progress = recorder?.progress() ?? (0, 0)
        store.writeState(RecorderState(status: status, pid: pid, frames: progress.0, duration: progress.1,
                                       error: error, updatedAt: Date()))
    }

    private func on(_ sig: Int32, _ handler: @escaping @MainActor () -> Void) {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.resume()
        sources.append(source)
    }

    private func begin(request: TargetRequest, name: String, fps: Int, wait: Double) {
        report("starting")
        on(SIGINT) { [unowned self] in finish() }
        on(SIGTERM) { [unowned self] in finish() }
        on(SIGUSR1) { [unowned self] in recorder?.pause(); report("paused") }
        on(SIGUSR2) { [unowned self] in recorder?.resume(); report("recording") }

        Task {
            do {
                // A window that is about to open is worth waiting for; anything else is not.
                let patience = Date().addingTimeInterval(wait)
                var target: CaptureTarget
                while true {
                    do {
                        target = try await Targets.resolve(request)
                        break
                    } catch let error as IrisError where error.description.hasPrefix("no window matches") && Date() < patience && !finishing {
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                let made = Recorder(target: target, store: store, name: name, fps: fps)
                made.onFailure = { message in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.finish(failure: message) } }
                }
                try await made.start()
                recorder = made
                report("recording")
                watch()
            } catch {
                report("failed", error: "\(error)")
                exit(1)
            }
        }
    }

    private func watch() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [unowned self] in
            MainActor.assumeIsolated {
                guard !finishing, let recorder else { return }
                report(recorder.isPaused ? "paused" : "recording")
                // An unattended recording must not run forever if its operator dies.
                if recorder.progress().duration >= maxDuration { finish() }
            }
        }
        timer.resume()
        ticker = timer
    }

    private func finish(failure: String? = nil) {
        guard !finishing else { return }
        finishing = true
        ticker?.cancel()
        Task {
            do {
                guard let recorder else { throw IrisError(failure ?? "the recording never started") }
                _ = try await recorder.stop()
                report(failure == nil ? "finished" : "failed", error: failure)
            } catch {
                report("failed", error: failure ?? "\(error)")
            }
            exit(failure == nil ? 0 : 1)
        }
    }
}

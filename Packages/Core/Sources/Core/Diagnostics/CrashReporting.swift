import Foundation
#if os(iOS) || os(macOS)
import MetricKit
#endif

/// What no `catch` can see: crashes (Swift traps, force-unwraps, signals),
/// hangs, CPU/disk-write exceptions, and uncaught Objective-C exceptions.
///
/// - MetricKit hands over the OS's own diagnostics for those (call stacks
///   included) on a later launch; each payload is kept as-is next to the
///   logs and summarized into the log at fault level.
/// - An uncaught Objective-C exception is logged and flushed synchronously
///   right before the process dies.
public enum CrashReporting {
    public static func install() {
        NSSetUncaughtExceptionHandler { exception in
            Log.fault(.lifecycle, "Uncaught exception", [
                "name": exception.name.rawValue,
                "reason": exception.reason ?? "",
                "stack": exception.callStackSymbols.prefix(40).joined(separator: "\n"),
            ])
            DiagnosticsLog.shared.flush()
        }
        #if os(iOS) || os(macOS)
        MetricKitReceiver.shared.start()
        #endif
        let info = Bundle.main.infoDictionary
        Log.notice(.lifecycle, "App launched", [
            "version": info?["CFBundleShortVersionString"] as? String ?? "?",
            "build": info?["CFBundleVersion"] as? String ?? "?",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
        ])
    }
}

#if os(iOS) || os(macOS)
private final class MetricKitReceiver: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitReceiver()

    func start() {
        let manager = MXMetricManager.shared
        manager.add(self)
        // Delivered before this launch subscribed (e.g. the crash that
        // ended the previous run).
        if #available(iOS 14.0, macOS 12.0, *) {
            didReceive(manager.pastDiagnosticPayloads)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let stamp = payload.timeStampEnd.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
            DiagnosticsLog.shared.store(payload.jsonRepresentation(), named: "metrickit-\(stamp).json")
            for crash in payload.crashDiagnostics ?? [] {
                Log.fault(.lifecycle, "Crash reported by the OS", [
                    "build": crash.metaData.applicationBuildVersion,
                    "exceptionType": crash.exceptionType.map { "\($0)" } ?? "-",
                    "exceptionCode": crash.exceptionCode.map { "\($0)" } ?? "-",
                    "signal": crash.signal.map { "\($0)" } ?? "-",
                    "reason": crash.terminationReason ?? "-",
                    "payload": "metrickit-\(stamp).json",
                ])
            }
            for hang in payload.hangDiagnostics ?? [] {
                Log.fault(.lifecycle, "Hang reported by the OS", [
                    "build": hang.metaData.applicationBuildVersion,
                    "duration": "\(hang.hangDuration)",
                    "payload": "metrickit-\(stamp).json",
                ])
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                Log.error(.lifecycle, "CPU exception reported by the OS", [
                    "build": cpu.metaData.applicationBuildVersion,
                    "cpuTime": "\(cpu.totalCPUTime)",
                    "payload": "metrickit-\(stamp).json",
                ])
            }
            for disk in payload.diskWriteExceptionDiagnostics ?? [] {
                Log.error(.lifecycle, "Disk-write exception reported by the OS", [
                    "build": disk.metaData.applicationBuildVersion,
                    "written": "\(disk.totalWritesCaused)",
                    "payload": "metrickit-\(stamp).json",
                ])
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let stamp = payload.timeStampEnd.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
            DiagnosticsLog.shared.store(payload.jsonRepresentation(), named: "metrickit-metrics-\(stamp).json")
        }
    }
}
#endif

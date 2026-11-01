import Foundation
import Darwin
import XCTest

/// Only the explicit owned Process PID is supervised; no process-name matching.
func waitForOwnedTestProcess(_ process: Process, seconds: Double = 20, file: StaticString = #filePath, line: UInt = #line) {
    let watchdog = DispatchWorkItem {
        guard process.isRunning else { return }
        XCTFail("Owned subprocess watchdog expired", file: file, line: line)
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now()+1) {
            if process.isRunning { kill(process.processIdentifier,SIGKILL) }
        }
    }
    DispatchQueue.global().asyncAfter(deadline:.now()+seconds,execute:watchdog)
    process.waitUntilExit();watchdog.cancel()
}

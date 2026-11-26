import Foundation
let state = "/tmp/v01-critic-repro/latin/state.txt"
let mode = ProcessInfo.processInfo.environment["FAKE_MODE"] ?? ""
func cur() -> String { (try? String(contentsOfFile: state, encoding: .utf8)) ?? "fake.Original" }
if CommandLine.arguments.count == 1 { print(cur()); exit(0) }
let req = CommandLine.arguments[1]
if req == "--ascii" {
  if mode == "noascii" { fputs("Requested source is not already enabled/selectable.\n", stderr); exit(75) }
  try! "fake.US".write(toFile: state, atomically: true, encoding: .utf8); print("fake.US"); exit(0)
}
if mode == "slowrestore" { sleep(3) }
try! req.write(toFile: state, atomically: true, encoding: .utf8); print(req)

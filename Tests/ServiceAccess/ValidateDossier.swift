import Foundation
import CryptoKit

// Native artifact validation only. No network, Keychain, browser or service credentials.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
var checks = 0
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
 checks += 1
 if !condition() { throw NSError(domain: "T08", code: checks, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func load(_ path: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(path))) }
func dict(_ value: Any) throws -> [String: Any] {
 guard let d = value as? [String: Any] else { throw NSError(domain: "T08-shape", code: 1) }; return d
}
func rows(_ value: Any) throws -> [[String: Any]] {
 guard let r = value as? [[String: Any]] else { throw NSError(domain: "T08-shape", code: 2) }; return r
}
func digest(_ path: String) throws -> String {
 let data = try Data(contentsOf: root.appendingPathComponent(path))
 return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) }
let deps = try rows(load("artifacts/harness/external-dependencies.json"))
let matrix = try dict(load("artifacts/harness/service-capability-matrix.json"))
let inventory = try dict(load("artifacts/harness/nodes/W08/inventory.json"))
let sources = try rows(load("artifacts/harness/nodes/W08/sources.json"))
let shapes = try dict(load("artifacts/harness/nodes/W08/protocol-shapes.json"))

// T08.1: exhaustive dependency IDs and concrete resources/owners/evidence/affected nodes.
try require(deps.count == 13, "13 dependency records required")
try require(Set(deps.compactMap { $0["id"] as? String }) == Set((1...13).map { String(format: "X%02d", $0) }), "dependency ID coverage")
for d in deps {
 for field in ["owner", "required_resource", "observed_status", "operator_request", "checked_at_utc"] {
  try require(!(d[field] as? String ?? "").isEmpty, "dependency field missing: \(field)")
 }
 try require(!(d["affected_nodes"] as? [String] ?? []).isEmpty, "affected nodes missing")
 try require(["unknown", "unresolved", "partially-observed"].contains(d["status"] as? String ?? ""), "unsupported closure from dossier")
 try require(d["unlocks_live_nodes"] as? Bool == false && d["gate_closure"] as? Bool == false, "dossier cannot unlock live nodes")
 let paths = d["evidence_paths"] as? [String] ?? []
 try require(!paths.isEmpty && paths.allSatisfy(exists), "dependency evidence absent")
}
print("T08.1 PASS — 13 concrete dependency records; unknowns retained")

// T08.2: actual capability rows must never inherit authority from weaker evidence.
let distinctions = try dict(matrix["distinctions"] as Any)
try require(distinctions.count == 6 && distinctions.values.allSatisfy { ($0 as? Bool) == false }, "evidence distinctions collapsed")
let cases = try rows(matrix["cases"] as Any)
try require(cases.count >= 12, "account/region/content/role matrix empty")
let classes = Set(cases.compactMap { $0["account_class"] as? String })
try require(classes.contains("free") && classes.contains("premium"), "both subscription classes required")
for c in cases {
 for f in ["region", "content", "ownership_role"] { try require(!(c[f] as? String ?? "").isEmpty, "case dimension missing") }
 let capabilities = try rows(c["capabilities"] as Any)
 try require(!capabilities.isEmpty, "case capabilities empty")
 for cap in capabilities {
  try require(cap["state"] as? String == "unknown", "unobserved account capability promoted")
  try require(cap["live_capture_id"] is NSNull && cap["grant_id"] is NSNull, "fabricated live grant")
 }
}
let gates = try dict(matrix["gate_status"] as Any)
try require(gates.count == 9 && gates.values.allSatisfy { ($0 as? String) == "open" }, "gate closed from documentation")
for field in ["music_session_exchange", "proposed_native_media", "proposed_ad_segment", "proposed_offline_entitlement", "proposed_receiver_load"] {
 let envelope = try dict(shapes[field] as Any)
 try require(envelope["status"] as? String == "unknown" && envelope["grant_id"] is NSNull, "proposal mislabeled provider grant")
}
print("T08.2 PASS — profile, Music, stream, offline, ads and Cast evidence remain distinct")

// T08.3: execution policy and requests must exclude forbidden access sources/actions.
let policy = try dict(inventory["policy"] as Any)
let forbidden = ["copied_browser_cookies", "password_capture", "excluded_resources_used", "proxy_backend", "personal_playlist_tests", "hidden_web_player", "third_party_messages", "other_app_secret_access", "extraction_or_bypass_executed"]
try require(Set(policy.keys) == Set(forbidden), "policy inventory mismatch")
for key in forbidden { try require(policy[key] as? Bool == false, "forbidden action recorded: \(key)") }
let project = try dict(inventory["project"] as Any)
try require(project["oauth_client_id"] is NSNull && project["oauth_project_id"] is NSNull, "unprovided registration invented")
let accounts = try rows(inventory["accounts"] as Any)
try require(accounts.count >= 6, "dedicated account resource inventory missing")
for a in accounts {
 try require(a["credentials_in_repository"] as? Bool == false, "credential persistence")
 try require((a["allowed_test_actions"] as? [String])?.isEmpty == true && a["status"] as? String == "not-provisioned", "unprovided account authorization")
}
try require((inventory["early_connection_requests"] as? [String]) == ["X01", "X02", "X03", "X04"], "early/later resources mixed")
print("T08.3 PASS — prohibited routes excluded; dedicated resources still unprovisioned")

// T08.4: every candidate operation has retrievable primary provenance and honest authorization.
try require(sources.count >= 19, "nonempty primary-source observation required")
let sourceIDs = Set(sources.compactMap { $0["id"] as? String })
for source in sources {
 try require(source["exit_code"] as? Int == 0 && exists(source["path"] as? String ?? ""), "source capture failed")
 try require((source["sha256"] as? String)?.count == 64 && !(source["retrieved_at_utc"] as? String ?? "").isEmpty, "source receipt missing")
 let actualDigest = try digest(source["path"] as? String ?? "")
 try require(actualDigest == source["sha256"] as? String, "primary source digest mismatch")
 try require(source["live_service_evidence"] as? Bool == false, "documentation mislabeled live")
}
let ops = try rows(matrix["operations"] as Any)
try require(ops.count >= 13, "operation coverage empty")
for op in ops {
 let refs = op["source_ids"] as? [String] ?? []
 try require(!refs.isEmpty && Set(refs).isSubset(of: sourceIDs), "operation provenance unresolved")
 try require(["documented-conditional", "unknown"].contains(op["status"] as? String ?? ""), "unsupported operation authorization")
 try require(!(op["authorization_record"] as? String ?? "").isEmpty, "authorization record missing")
 try require(op["live_capture_id"] is NSNull && op["grant_id"] is NSNull, "reference claim inflated to live")
}
let codeFiles = try rows(load("artifacts/harness/nodes/W08/reference-code/files.json"))
try require(codeFiles.count >= 20, "code comparison evidence empty")
try require(Set(codeFiles.compactMap { $0["repo"] as? String }).count == 4, "four inspected sources required")
for file in codeFiles {
 try require(file["exit_code"] as? Int == 0 && exists(file["path"] as? String ?? "") && (file["commit"] as? String)?.count == 40, "unpinned/failed reference source")
 let actualDigest = try digest(file["path"] as? String ?? "")
 try require(actualDigest == file["sha256"] as? String, "reference source digest mismatch")
}
print("T08.4 PASS — documented candidates have primary provenance; references are not live evidence")
print("T08 PASS — 4 cases, \(checks) assertions, 0 failures; dependency-evidence layer only")

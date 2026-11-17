import Testing
import Foundation
@testable import OrbitDeck

// MARK: - Log data integrity: ADIF hardening, Cloudlog reply/URL policy, upload marking,
//         and preserving an unreadable log file instead of overwriting it.

struct ADIFHardeningTests {

    @Test func hugeFieldLengthDoesNotOverflow() {
        let parsed = ADIF.parse("<EOH><CALL:9223372036854775807>W1AW <EOR>")
        // The length runs past the end, so the value is clamped to the rest of the file.
        #expect(parsed.count == 1)
        #expect(parsed.first?.call.hasPrefix("W1AW") == true)
    }

    @Test func nonFiniteAndHugeFrequenciesAreIgnored() {
        let parsed = ADIF.parse("<CALL:4>W1AW <FREQ:3>inf <FREQ_RX:3>nan <EOR><CALL:4>K1AB <FREQ:6>1e3000 <FREQ_RX:5>1e300 <EOR>")
        #expect(parsed.count == 2)
        #expect(parsed.allSatisfy { $0.ulHz == 0 && $0.dlHz == 0 })
        #expect(ADIF.hertz("-inf") == nil)
        #expect(ADIF.hertz("-1") == nil)
        #expect(ADIF.hertz("145.950") == 145_950_000)
        #expect(ADIF.hertz(" 435.300 ") == 435_300_000)
    }

    @Test func truncatedFilesDoNotCrash() {
        for text in ["", "<", "<CALL", "<CALL:", "<CALL:4", "<CALL:4>", "<CALL:4>W1", "<EOH>", "<EOH><CALL:4>W1AW <MODE",
                     "<CALL:-5>W1AW <EOR>", "<CALL:99999999999999999999>W1AW <EOR>", "<EOH><CALL:4>W1AW <FREQ:7>145.9"] {
            _ = ADIF.parse(text)
        }
        let partial = ADIF.parse("<EOH><CALL:4>W1AW <FREQ:7>145.9")
        #expect(partial.first?.call == "W1AW")
        #expect(partial.first?.ulHz == 145_900_000)
    }
}

struct CloudlogResponseTests {

    private func classify(_ json: String, code: Int = 201, sent: Int) -> Cloudlog.UploadOutcome {
        Cloudlog.classify(statusCode: code, body: Data(json.utf8), sent: sent)
    }

    private func failureText(_ outcome: Cloudlog.UploadOutcome) -> String? {
        if case .failure(let e) = outcome { return e.errorDescription }
        return nil
    }

    @Test func createdWithMatchingCountSucceeds() {
        #expect(classify(#"{"status":"created","imported_count":3,"messages":[]}"#, sent: 3) == .success(3))
        // Cloudlog adds an empty message per clean record.
        #expect(classify(#"{"status":"created","imported_count":2,"messages":["",""]}"#, sent: 2) == .success(2))
        // Wavelog
        #expect(classify(#"{"status":"created","type":"adif","adif_count":2,"adif_errors":0,"messages":[]}"#, sent: 2) == .success(2))
    }

    @Test func createdWithRejectedRecordsFails() {
        let out = classify(#"{"status":"created","imported_count":3,"messages":["","Duplicate for W1AW",""]}"#, sent: 3)
        let text = failureText(out)
        #expect(text?.contains("Duplicate for W1AW") == true)
    }

    @Test func countMismatchFails() {
        let text = failureText(classify(#"{"status":"created","imported_count":1,"messages":[]}"#, sent: 4))
        #expect(text?.contains("1 of 4") == true)
        // No count at all is not proof either.
        #expect(failureText(classify(#"{"status":"created"}"#, sent: 1)) != nil)
    }

    @Test func wavelogErrorsFail() {
        let created = classify(#"{"status":"created","adif_count":2,"adif_errors":1,"messages":["Wrong band for 145.9"]}"#, sent: 2)
        let text = failureText(created)
        #expect(text?.contains("Wrong band for 145.9") == true)
        #expect(text?.contains("1 record(s) had errors") == true)

        let abort = classify(#"{"status":"abort","adif_count":2,"adif_errors":2,"messages":["bad record"]}"#, code: 400, sent: 2)
        #expect(failureText(abort)?.contains("HTTP 400") == true)
        #expect(failureText(abort)?.contains("bad record") == true)

        let unauthorized = classify(#"{"status":"failed","reason":"station callsign does not match"}"#, code: 401, sent: 2)
        #expect(failureText(unauthorized)?.contains("station callsign does not match") == true)
    }

    @Test func nonJSONReplyIsNotSuccess() {
        let out = classify("<html><body>Fatal error</body></html>", code: 200, sent: 1)
        #expect(failureText(out)?.contains("not JSON") == true)
        #expect(failureText(classify("", code: 201, sent: 1)) != nil)
    }
}

struct CloudlogURLPolicyTests {

    private func isSecure(_ s: String) -> Bool { if case .secure = Cloudlog.checkURL(s) { true } else { false } }
    private func isLocal(_ s: String) -> Bool { if case .cleartextLocal = Cloudlog.checkURL(s) { true } else { false } }
    private func isBlocked(_ s: String) -> Bool { if case .blocked = Cloudlog.checkURL(s) { true } else { false } }

    @Test func httpsIsAllowed() {
        #expect(isSecure("https://cloudlog.example.com"))
        #expect(isSecure("https://cloudlog.example.com/index.php"))
        if case .secure(let url) = Cloudlog.checkURL("https://log.example.org/") {
            #expect(url.absoluteString == "https://log.example.org/index.php/api/qso")
        }
    }

    @Test func httpOnLocalNetworkIsAllowedWithWarning() {
        for url in ["http://192.168.1.5", "http://10.0.0.2:8080/cloudlog", "http://172.20.1.1", "http://169.254.3.4",
                    "http://127.0.0.1", "http://localhost", "http://shack.local", "http://shack.local.", "http://shack",
                    "http://[fd12:3456::1]", "http://[fe80::1]", "http://[::1]"] {
            #expect(isLocal(url), "\(url)")
        }
        #expect(!Cloudlog.cleartextWarning.isEmpty)
    }

    @Test func httpToInternetIsBlocked() {
        for url in ["http://cloudlog.example.com", "http://8.8.8.8", "http://172.32.0.1", "http://[2001:db8::1]",
                    "ftp://cloudlog.example.com", "cloudlog.example.com"] {
            #expect(isBlocked(url), "\(url)")
        }
        if case .blocked(let reason) = Cloudlog.checkURL("http://cloudlog.example.com") {
            #expect(reason.contains("Use https:// for internet hosts"))
        }
        #expect(Cloudlog.checkURL("  ") == nil)
    }
}

struct UploadMarkingTests {

    private func qso(_ call: String) -> QSORecord {
        var q = QSORecord(utc: Date(timeIntervalSince1970: 1_700_000_000))
        q.call = call; q.sat = "AO-91"; q.mode = "FM"
        return q
    }

    @Test func editedDuringUploadIsNotMarked() {
        let a = qso("W1AW"), b = qso("K1ABC"), c = qso("N8HM")
        let sent = [a, b, c]
        var log = sent
        log[1].grid = "FN42"          // an ADIF-only edit while the upload was in flight
        log[2].call = "N8HN"          // a contact-field edit
        let marked = QSOStore.markUploaded(&log, sent: sent, flag: .cloudlog)
        #expect(marked == 1)
        #expect(log[0].uploaded.contains(.cloudlog))
        #expect(!log[1].uploaded.contains(.cloudlog))
        #expect(!log[2].uploaded.contains(.cloudlog))

        // A grid edit doesn't touch what LoTW signs, so LoTW still marks it.
        var lotwLog = sent
        lotwLog[1].grid = "FN42"
        #expect(QSOStore.markUploaded(&lotwLog, sent: sent, flag: .lotw) == 3)
        #expect(lotwLog[1].uploaded.contains(.lotw))
    }

    @Test func deletedOrUnsentQSOsAreNotMarked() {
        let a = qso("W1AW"), b = qso("K1ABC")
        var log = [b]                  // a was deleted mid-upload; b was never sent
        #expect(QSOStore.markUploaded(&log, sent: [a], flag: .lotw) == 0)
        #expect(log[0].uploaded.isEmpty)
    }
}

struct LogFilePreservationTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LogIntegrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func corruptLogIsMovedAsideNotOverwritten() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("QSOLog.json")
        let garbage = Data("[{\"id\": \"not-a-uuid\", truncated".utf8)
        try garbage.write(to: url)

        let now = Date(timeIntervalSince1970: 1_763_294_400)     // 2025-11-16 12:00:00 UTC
        let result = QSOStore.loadOrPreserve([QSORecord].self, at: url, now: now)
        guard case .preserved(let dest, let reason) = result else {
            Issue.record("expected the corrupt file to be preserved"); return
        }
        #expect(!reason.isEmpty)
        #expect(dest.lastPathComponent == "QSOLog.corrupt-20251116T120000Z.json")
        #expect(dest.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(try Data(contentsOf: dest) == garbage)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // A second corrupt file in the same second gets its own name.
        try garbage.write(to: url)
        guard case .preserved(let second, _) = QSOStore.loadOrPreserve([QSORecord].self, at: url, now: now) else {
            Issue.record("expected the second corrupt file to be preserved"); return
        }
        #expect(second != dest)
        #expect(try Data(contentsOf: dest) == garbage)
    }

    @Test func missingAndValidFilesLoad() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("QSOLog.json")
        guard case .missing = QSOStore.loadOrPreserve([QSORecord].self, at: url) else {
            Issue.record("expected missing"); return
        }
        var q = QSORecord(utc: Date(timeIntervalSince1970: 1_700_000_000)); q.call = "W1AW"
        try JSONEncoder().encode([q]).write(to: url)
        guard case .loaded(let records) = QSOStore.loadOrPreserve([QSORecord].self, at: url) else {
            Issue.record("expected loaded"); return
        }
        #expect(records == [q])
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

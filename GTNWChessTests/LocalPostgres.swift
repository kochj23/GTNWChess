import XCTest
@testable import GTNWChess

/// A throwaway Postgres 17 for the integration tests: initdb'd into a temp folder, TLS only (hostssl + scram-sha-256,
/// self-signed CA with SAN localhost/127.0.0.1), random passwords, the shared `play` schema from the vendored
/// NovaGames play.sql and the role `gtnwchess_mac` like the games DB. Never the real games DB.
final class LocalPostgres: @unchecked Sendable {
    static let binDir = ["/opt/homebrew/opt/postgresql@17/bin", "/opt/homebrew/bin"]
        .first { FileManager.default.isExecutableFile(atPath: $0 + "/initdb") }

    let dir: URL
    let port: Int
    let caPEM: [UInt8]
    private(set) var passwords: [String: String] = [:]
    var caURL: URL { dir.appendingPathComponent("ca.crt") }

    nonisolated(unsafe) private static var _shared: LocalPostgres?
    private static let lock = NSLock()

    static func require() throws -> LocalPostgres {
        guard binDir != nil else { throw XCTSkip("Postgres 17 not installed") }
        return try lock.withLock {
            if let s = _shared { return s }
            let s = try LocalPostgres()
            _shared = s
            let observer = StopAtEnd(s)
            if Thread.isMainThread { XCTestObservationCenter.shared.addTestObserver(observer) }
            else { DispatchQueue.main.sync { XCTestObservationCenter.shared.addTestObserver(observer) } }
            return s
        }
    }

    init() throws {
        guard let bin = Self.binDir else { throw XCTSkip("no Postgres") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("gc-pg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        port = Self.freePort()
        for r in ["postgres", "gtnwchess_mac", "other_writer"] { passwords[r] = UUID().uuidString.replacingOccurrences(of: "-", with: "") }
        let pw = dir.appendingPathComponent("su.pw")
        try passwords["postgres"]!.write(to: pw, atomically: true, encoding: .utf8)
        let data = dir.appendingPathComponent("data").path
        try Self.run(bin + "/initdb", ["-D", data, "-U", "postgres", "--auth=scram-sha-256", "--pwfile=\(pw.path)", "-E", "UTF8", "--no-locale"])
        // An internal CA and a server certificate it signs (like the games DB): SAN localhost/127.0.0.1, serverAuth.
        let ca = dir.appendingPathComponent("ca.crt"), cakey = dir.appendingPathComponent("ca.key")
        let crt = dir.appendingPathComponent("server.crt"), key = dir.appendingPathComponent("server.key")
        let csr = dir.appendingPathComponent("server.csr"), ext = dir.appendingPathComponent("server.ext")
        try Self.run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes",
                                          "-keyout", cakey.path, "-out", ca.path, "-days", "3", "-subj", "/CN=Test Games DB CA",
                                          "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"])
        try Self.run("/usr/bin/openssl", ["req", "-new", "-newkey", "rsa:2048", "-nodes",
                                          "-keyout", key.path, "-out", csr.path, "-subj", "/CN=localhost"])
        try "subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature\n"
            .write(to: ext, atomically: true, encoding: .utf8)
        try Self.run("/usr/bin/openssl", ["x509", "-req", "-in", csr.path, "-CA", ca.path, "-CAkey", cakey.path, "-CAcreateserial",
                                          "-out", crt.path, "-days", "3", "-extfile", ext.path])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dir.appendingPathComponent("server.key").path)
        try "hostssl all all 127.0.0.1/32 scram-sha-256\n".write(toFile: data + "/pg_hba.conf", atomically: true, encoding: .utf8)
        caPEM = [UInt8](try Data(contentsOf: ca))
        let opts = "-c listen_addresses=127.0.0.1 -c port=\(port) -c unix_socket_directories='' -c ssl=on " +
            "-c ssl_cert_file=\(crt.path) -c ssl_key_file=\(dir.appendingPathComponent("server.key").path) -c fsync=off"
        try Self.run(bin + "/pg_ctl", ["-D", data, "-l", dir.appendingPathComponent("log").path, "-w", "-t", "30", "start", "-o", opts])
        // The other games' writer roles exist because play.sql grants to all of them.
        try psql("""
            CREATE DATABASE games;
            """)
        try psql("""
            CREATE ROLE gtnw NOLOGIN; CREATE ROLE cartest NOLOGIN; CREATE ROLE blompie NOLOGIN; CREATE ROLE mush NOLOGIN;
            CREATE ROLE saves NOLOGIN; CREATE ROLE blompie_mac NOLOGIN; CREATE ROLE casting NOLOGIN; CREATE ROLE stuntdriver_mac NOLOGIN;
            CREATE ROLE gtnwchess_mac LOGIN NOINHERIT PASSWORD '\(passwords["gtnwchess_mac"]!)';
            ALTER ROLE gtnwchess_mac SET search_path = play;
            GRANT CONNECT ON DATABASE games TO gtnwchess_mac;
            """, db: "games")
        let url = try XCTUnwrap(Bundle(for: LocalPostgres.self).url(forResource: "play", withExtension: "sql"))
        try psql("", db: "games", file: url)
        // A second writer (stands in for another game) to prove row-level security.
        try psql("""
            CREATE ROLE other_writer LOGIN NOINHERIT PASSWORD '\(passwords["other_writer"]!)';
            GRANT CONNECT ON DATABASE games TO other_writer; GRANT USAGE ON SCHEMA play TO other_writer;
            GRANT SELECT, INSERT, UPDATE ON play.sessions, play.events TO other_writer;
            CREATE POLICY own_other ON play.sessions FOR ALL TO other_writer USING (writer = current_user) WITH CHECK (writer = current_user);
            """, db: "games")
    }

    func config(user: String = "gtnwchess_mac") -> PGConfig {
        var c = PGConfig()
        c.host = "127.0.0.1"; c.tlsServerName = "localhost"; c.port = port; c.database = "games"; c.user = user
        c.caPEM = caPEM; c.timeout = 5
        return c
    }

    @discardableResult
    func psql(_ sql: String, db: String = "postgres", file: URL? = nil) throws -> String {
        guard let bin = Self.binDir else { throw XCTSkip("no psql") }
        var args = ["-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-h", "127.0.0.1", "-p", String(port), "-U", "postgres", "-d", db]
        if let file { args += ["-f", file.path] } else { args += ["-c", sql] }
        return try Self.run(bin + "/psql", args, env: ["PGPASSWORD": passwords["postgres"]!, "PGSSLMODE": "verify-full",
                                                      "PGSSLROOTCERT": caURL.path])
    }

    func destroy() {
        if let bin = Self.binDir {
            _ = try? Self.run(bin + "/pg_ctl", ["-D", dir.appendingPathComponent("data").path, "-m", "fast", "-w", "stop"])
        }
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String], env: [String: String] = [:]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        e["LC_ALL"] = "en_US.UTF-8"; e["LANG"] = "en_US.UTF-8"
        for (k, v) in env { e[k] = v }
        p.environment = e
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "LocalPostgres", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\((exe as NSString).lastPathComponent): \(String(decoding: r, as: UTF8.self))"])
        }
        return String(decoding: o, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private final class StopAtEnd: NSObject, XCTestObservation {
        let pg: LocalPostgres
        init(_ pg: LocalPostgres) { self.pg = pg }
        func testBundleDidFinish(_ testBundle: Bundle) { pg.destroy() }
    }
}

/// A TCP listener that accepts and never answers: a hung server for timeout tests.
final class SilentListener {
    let port: Int
    private let fd: Int32
    init() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        listen(fd, 16)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = Int(UInt16(bigEndian: addr.sin_port))
    }
    deinit { close(fd) }
}

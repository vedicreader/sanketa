import Foundation
import Testing

/// make variables reach recipes only after a check, so `make test FILTER=…` cannot run other commands.
@Suite struct MakefileGuardTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `make -n` prints the recipes and runs none; only `$(shell)` in a value could still run, so that is tested too.
    func make(_ args: [String]) throws -> (status: Int32, out: String, err: String) {
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        p.arguments = ["-n", "-C", Self.repo.path] + args
        // under `make test` the outer make exports its flags and values; drop them so each case sees only its own args
        let inherited: Set = ["MAKEFLAGS", "MFLAGS", "MAKELEVEL", "FILTER", "PACKS", "SHOTS", "HOST", "INSTALL_DIR", "ZIP",
                              "SIGN_ID", "RELEASE_ID", "VERSION"]
        p.environment = ProcessInfo.processInfo.environment.filter { !inherited.contains($0.key) }
        p.standardOutput = out; p.standardError = err
        try p.run()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, o, e)
    }

    @Test func refusesUnsafeValues() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-pwned-\(UUID().uuidString)")
        for args in [["test", "FILTER=x';echo pwned;'"], ["test", "FILTER=$(shell touch \(marker.path))"], ["test", "FILTER=a b"],
                     ["lint", "PACKS=x;id"], ["shots", "SHOTS=`id`"], ["remote-setup", "HOST=me@gpubox;id"],
                     // a leading - would be an option: ssh -oProxyCommand runs a command
                     ["remote-setup", "HOST=-oProxyCommand"], ["lint", "PACKS=-x"], ["test", "FILTER=-h"], ["install", "INSTALL_DIR=-x"],
                     ["app", "SIGN_ID=Apple Development\"; touch \(marker.path); \""], ["app", "SIGN_ID=$(shell touch \(marker.path))"],
                     ["zip", "ZIP=x;touch \(marker.path)"],
                     // the xcodebuild paths go into recipes as text, so they are checked too
                     ["bundle", "XCODE_DATA=x;touch \(marker.path)"], ["test-mlx", "XCODE_DATA=$(shell touch \(marker.path))"],
                     ["bundle", "XCODE_DATA=`id`"], ["verify", "APP=x;id"], ["bundle", "XCODE_DATA=-x"], ["zip", "STABLE_ZIP=x;touch \(marker.path)"]] {
            let r = try make(args)
            #expect(r.status == 2, "\(args)")
            #expect(r.err.contains("is not safe") || r.err.contains("must not start with -"), "\(args): \(r.err)")
            #expect(r.out.isEmpty, "\(args): \(r.out)")
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// Runs /usr/bin/make on a temp makefile that includes mk/no-dry-run.mk and has a harmless `release` target, so
    /// no case can reach the real release recipe (codesign, notarize.sh, gh).
    func guardMake(_ args: [String], makeflags: String? = nil) throws -> (status: Int32, out: String, err: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-ndr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let guardFile = Self.repo.appendingPathComponent("mk/no-dry-run.mk").path
        try "include \(guardFile)\n$(info MAKEFLAGS=[$(MAKEFLAGS)])\nrelease:\n\t@echo ran\n".write(
            to: dir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        p.arguments = ["-C", dir.path] + args + ["release"]
        var env = ProcessInfo.processInfo.environment.filter { !["MAKEFLAGS", "MFLAGS", "MAKELEVEL"].contains($0.key) }
        env["MAKEFLAGS"] = makeflags
        p.environment = env
        p.standardOutput = out; p.standardError = err
        try p.run()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, o, e)
    }

    @Test func dryRunGuardRefusesEveryForm() throws {
        let cases: [[String]] = [["-n"], ["--dry-run"], ["--just-print"], ["--recon"], ["-nB"], ["-k", "-n"], ["-kn"],
                                 ["-n", "-j4"], ["-j4", "-n"], ["-n", "--no-print-directory"], ["--dry-run", "--no-print-directory"],
                                 ["--warn-undefined-variables", "-n"]]
        for args in cases {
            let r = try guardMake(args)
            #expect(r.status == 2 && r.err.contains("release and publish do not run with -n"), "\(args): \(r.out) \(r.err)")
            #expect(!r.out.contains("ran"), "\(args): \(r.out)")
        }
        for flags in ["n", "-n", "--dry-run", "--dry-run --no-print-directory"] {
            let r = try guardMake([], makeflags: flags)
            #expect(r.status == 2 && r.err.contains("release and publish do not run with -n"), "MAKEFLAGS=\(flags): \(r.out) \(r.err)")
            #expect(!r.out.contains("ran"), "MAKEFLAGS=\(flags): \(r.out)")
        }
    }

    @Test func dryRunGuardLetsRealRunsThrough() throws {
        for args in [["-k"], ["-j4"], ["--no-print-directory"], []] {
            let r = try guardMake(args)
            #expect(r.status == 0 && r.out.contains("ran"), "\(args): \(r.out) \(r.err)")
        }
    }

    /// VERSION feeds the ZIP default, so it is checked before anything expands it.
    @Test func refusesUnsafeVersion() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-pwned-\(UUID().uuidString)")
        for v in ["$(shell touch \(marker.path))", "1.0;id", "-1"] {
            let r = try make(["zip", "VERSION=\(v)"])
            #expect(r.status == 2, "\(v)")
            #expect(r.err.contains("VERSION"), "\(v): \(r.err)")
            #expect(r.out.isEmpty, "\(v): \(r.out)")
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func safeValuesPassThroughTheEnvironment() throws {
        let r = try make(["test", "FILTER=PackLint", "lint", "PACKS=Resources/Packs/yazi.toml", "remote-setup", "HOST=me@gpubox",
                          "app", "SIGN_ID=Apple Development: Jane Doe (AB12CD34EF)", "zip", "ZIP=dist/x.zip", "install", "INSTALL_DIR=/tmp/apps"])
        #expect(r.status == 0, "\(r.err)")
        #expect(r.out.contains(#"swift test --filter "$FILTER""#) && r.out.contains(#"--lint-pack "$PACKS""#)
                && r.out.contains(#"scripts/remote-setup.sh "$HOST""#) && r.out.contains(#"--sign "$SIGN_ID""#)
                && r.out.contains(#"--keepParent build/Sanketa.app "$ZIP""#) && r.out.contains(#""$INSTALL_DIR/Sanketa.app""#))
        // the ad-hoc identity for CI still works
        #expect(try make(["app", "SIGN_ID=-"]).status == 0)
    }
}

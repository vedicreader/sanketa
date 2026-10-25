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
                     ["bundle", "XCODE_DATA=`id`"], ["verify", "APP=x;id"], ["bundle", "XCODE_DATA=-x"], ["zip", "STABLE_ZIP=x;touch \(marker.path)"],
                     ["zip", "NOTES=x;touch \(marker.path)"], ["zip", "NOTES=-x"],
                     // the check's own variables are override, so the command line cannot turn the check off
                     ["test", "FILTER=x;id", "check_var="], ["test", "FILTER=x;id", "SAFE_CHARS=x ; i d"], ["test", "FILTER=x;id", "strip_chars="]] {
            let r = try make(args)
            #expect(r.status == 2, "\(args)")
            #expect(r.err.contains("is not safe") || r.err.contains("must not start with -"), "\(args): \(r.err)")
            #expect(r.out.isEmpty, "\(args): \(r.out)")
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        // a recipe macro from the command line is ignored
        let z = try make(["zip", "ZIP_APP=touch \(marker.path)"])
        #expect(z.status == 0 && z.out.contains("ditto -c -k") && !z.out.contains(marker.path), "\(z.out) \(z.err)")
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
                                 ["--warn-undefined-variables", "-n"],
                                 // the guard's own variables are override, so the command line cannot empty them
                                 ["-n", "ndr_words="], ["-n", "ndr_short=", "ndr_flags="], ["-n", "ndr_letters=x"]]
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

    /// Runs /usr/bin/make on a temp makefile that includes mk/release.mk with harmless stand-ins for codesign,
    /// notarize.sh, stapler and gh (`echo GH-UPLOAD`), on a folder that stands in for the app. `check` replaces the
    /// notarization check; nil keeps the real one (`xcrun stapler validate`, which fails on a folder with no ticket).
    func releaseMake(_ args: [String], notarize: Int, check: String? = "true",
                     env extra: [String: String] = [:]) throws -> (status: Int32, out: String, err: String, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-rel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mk = Self.repo.appendingPathComponent("mk/release.mk").path
        try """
        APP := build/Sanketa.app
        VERSION := 0.0.0
        ifeq ($(origin ZIP),undefined)
        ZIP := dist/Sanketa-$(VERSION).zip
        endif
        STABLE_ZIP := dist/Sanketa.zip
        NOTES := dist/notes-$(VERSION).md
        export ZIP
        include \(mk)
        override CODESIGN := :
        override NOTARIZE := sh -c 'exit \(notarize)' sh
        override STAPLE := :
        \(check.map { "override CHECK_NOTARIZED = \($0)" } ?? "")
        override GH := echo GH-UPLOAD
        bundle:
        \tmkdir -p $(APP)/Contents && echo app > $(APP)/Contents/Info.plist

        """.write(to: dir.appendingPathComponent("Makefile"), atomically: true, encoding: .utf8)
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        p.arguments = ["-C", dir.path] + args
        let inherited: Set = ["MAKEFLAGS", "MFLAGS", "MAKELEVEL", "ZIP", "VERSION", "NOTARY_PROFILE", "NOTARY_CONFIG", "NOTARY_KEY_PATH"]
        p.environment = ProcessInfo.processInfo.environment.filter { !inherited.contains($0.key) }.merging(extra) { $1 }
        p.standardOutput = out; p.standardError = err
        try p.run()
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, o, e, dir)
    }

    /// publish uploads only an app that is notarized, stapled and checked; release fails without notary credentials.
    @Test func publishUploadsOnlyANotarizedApp() throws {
        let fm = FileManager.default
        for (notarize, check, why) in [(3, "true", "no credentials"), (1, "true", "notarization failed"),
                                       (0, "false", "the check fails"), (0, nil, "real stapler validate, no ticket")] as [(Int, String?, String)] {
            let r = try releaseMake(["publish"], notarize: notarize, check: check)
            #expect(r.status != 0, "\(why): \(r.out) \(r.err)")
            #expect(!r.out.contains("GH-UPLOAD"), "\(why): \(r.out)")
            #expect(!fm.fileExists(atPath: r.dir.appendingPathComponent("dist/notes-0.0.0.md").path), "\(why): no notes")
            #expect(!fm.fileExists(atPath: r.dir.appendingPathComponent("dist/Sanketa.zip").path), "\(why): no stable zip")
        }
        let none = try releaseMake(["release"], notarize: 3)
        #expect(none.status != 0 && none.err.contains("found no notary credentials"), "\(none.out) \(none.err)")

        let ok = try releaseMake(["publish"], notarize: 0)
        #expect(ok.status == 0, "\(ok.out) \(ok.err)")
        #expect(ok.out.contains("GH-UPLOAD release create v0.0.0 dist/Sanketa-0.0.0.zip dist/Sanketa.zip --target main"), "\(ok.out)")
        let notes = try String(contentsOf: ok.dir.appendingPathComponent("dist/notes-0.0.0.md"), encoding: .utf8)
        #expect(notes.contains("Apple notarized it") && notes.contains("Sanketa.zip has a name that does not change"), "\(notes)")
        #expect(fm.contentsEqual(atPath: ok.dir.appendingPathComponent("dist/Sanketa.zip").path,
                                 andPath: ok.dir.appendingPathComponent("dist/Sanketa-0.0.0.zip").path))
    }

    /// release and publish take VERSION only from Info.plist (here the makefile), and publish its own ZIP name.
    @Test func releaseRefusesVersionAndZipFromOutside() throws {
        for (args, env) in [(["publish", "VERSION=9.9.9"], [:]), (["release", "VERSION=9.9.9"], [:]),
                            (["-e", "publish"], ["VERSION": "9.9.9"]), (["publish", "ZIP=dist/x.zip"], [:]),
                            (["publish"], ["ZIP": "dist/x.zip"])] as [([String], [String: String])] {
            let r = try releaseMake(args, notarize: 0, env: env)
            #expect(r.status == 2 && (r.err.contains("Do not set VERSION") || r.err.contains("Do not set ZIP")), "\(args) \(env): \(r.err)")
            #expect(!r.out.contains("mkdir") && !r.out.contains("GH-UPLOAD"), "\(args) \(env): \(r.out)")
        }
        // the version in the file still works, and so does a ZIP for release alone
        #expect(try releaseMake(["release", "ZIP=dist/x.zip"], notarize: 0).status == 0)
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

import Testing
import Foundation
@testable import SanketaMLX

/// A fresh temp folder for one test.
private func mlxTempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("sanketa-mlx-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func touch(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: url)
}

@Test func metallibFoundInBundleLayout() throws {
    let app = try mlxTempDir().appendingPathComponent("Fake.app")
    let exe = app.appendingPathComponent("Contents/MacOS/Sanketa")
    let lib = app.appendingPathComponent("Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    try touch(exe); try touch(lib)
    let bundle = try #require(Bundle(url: app))
    #expect(MLXRuntime.metallibURL(bundle: bundle, executable: exe, code: bundle)?.resolvingSymlinksInPath() == lib.resolvingSymlinksInPath())
    try FileManager.default.moveItem(at: lib, to: app.deletingLastPathComponent().appendingPathComponent("default.metallib"))
    #expect(MLXRuntime.metallibURL(bundle: bundle, executable: exe, code: bundle) == nil)
}

@Test func metallibFoundNextToExecutable() throws {
    let dir = try mlxTempDir()
    let exe = dir.appendingPathComponent("Sanketa"), lib = dir.appendingPathComponent("mlx.metallib")
    try touch(exe)
    let bundle = try #require(Bundle(url: dir))
    #expect(MLXRuntime.metallibURL(bundle: bundle, executable: exe, code: bundle) == nil)
    try touch(lib)
    #expect(MLXRuntime.metallibURL(bundle: bundle, executable: exe, code: bundle)?.resolvingSymlinksInPath() == lib.resolvingSymlinksInPath())
}

@Test func metallibFoundBesideTestBundle() throws {
    let dir = try mlxTempDir()
    let tests = dir.appendingPathComponent("Fake.xctest"), lib = dir.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
    try touch(tests.appendingPathComponent("Contents/MacOS/Fake"))
    let code = try #require(Bundle(url: tests)), other = try #require(Bundle(url: try mlxTempDir()))
    #expect(MLXRuntime.metallibURL(bundle: other, executable: nil, code: code) == nil)
    try touch(lib)
    #expect(MLXRuntime.metallibURL(bundle: other, executable: nil, code: code)?.resolvingSymlinksInPath() == lib.resolvingSymlinksInPath())
    // only a test bundle's folder counts: the folder of an app is not searched
    let app = dir.appendingPathComponent("Fake.app")
    try touch(app.appendingPathComponent("Contents/MacOS/Fake"))
    #expect(MLXRuntime.metallibURL(bundle: other, executable: nil, code: try #require(Bundle(url: app))) == nil)
}

@Test func gpuCheckDegradesWithoutMetallib() {
    #expect(MLXRuntime.gpuCheck(ready: false) == nil)
}

/// Runs only where the shaders are built (make test-mlx through xcodebuild).
@Test(.enabled(if: MLXRuntime.isReady)) func gpuCheckRunsWithMetallib() {
    #expect(MLXRuntime.gpuCheck() == 10)
}

import Foundation
import SanketaCore

/// Stops the tmux server on each `-L` socket in `socks`, then deletes its socket file.
/// tmux 3.7 leaves the socket file after `kill-server`, so without the delete every test run adds dead sockets to
/// `$TMUX_TMPDIR/tmux-<uid>/`. The path follows tmux's rule: `$TMUX_TMPDIR`, else `/tmp`.
func stopTmux(_ socks: String..., timeout: TimeInterval = 15) {
    let r = ProcessRunner()
    let dir = (ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/tmp") + "/tmux-\(getuid())"
    for s in socks {
        _ = r.run(tmuxBin, ["-L", s, "kill-server"], timeout: timeout)
        try? FileManager.default.removeItem(atPath: "\(dir)/\(s)")
    }
}

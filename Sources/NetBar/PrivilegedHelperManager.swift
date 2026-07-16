import Foundation
import Darwin

enum PrivilegedAccessState: Equatable {
    case ready
    case notConfigured
    case needsRepair

    var title: String {
        switch self {
        case .ready: return "免密码网络切换已启用"
        case .notConfigured: return "首次配置后即可免密码切换"
        case .needsRepair: return "免密码权限需要修复"
        }
    }
}

final class PrivilegedHelperManager {
    static let installedHelperPath = "/Library/PrivilegedHelperTools/local.codex.NetBarHelper"
    // sudo ignores included-directory entries whose filename contains a dot.
    static let sudoersPath = "/etc/sudoers.d/local_codex_netbar"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var bundledHelperURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/PrivilegedHelperTools/NetBarHelper")
        return fileManager.isExecutableFile(atPath: url.path) ? url : nil
    }

    var state: PrivilegedAccessState {
        let helperExists = fileManager.isExecutableFile(atPath: Self.installedHelperPath)
        let sudoersExists = fileManager.fileExists(atPath: Self.sudoersPath)
        guard helperExists || sudoersExists else { return .notConfigured }
        guard helperExists, sudoersExists, hasSafeOwnership(path: Self.installedHelperPath),
              hasSafeOwnership(path: Self.sudoersPath) else { return .needsRepair }
        do {
            let output = try CommandRunner.run("/usr/bin/sudo", ["-n", Self.installedHelperPath, "status"])
            return output.contains("NetBarHelper ready") ? .ready : .needsRepair
        } catch {
            return .needsRepair
        }
    }

    func configureForCurrentUser() throws {
        guard let source = bundledHelperURL else {
            throw NetworkError.commandFailed("应用包内缺少权限助手，请重新安装完整的 NetBar.app。")
        }
        let username = NSUserName()
        guard username.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil else {
            throw NetworkError.commandFailed("当前用户名包含权限配置不支持的字符。")
        }

        let script = #"""
        set -eu
        source="$1"
        target="$2"
        sudoers="$3"
        account="$4"
        case "$account" in ''|*[!A-Za-z0-9._-]*) exit 64 ;; esac
        /usr/bin/install -d -o root -g wheel -m 0755 /Library/PrivilegedHelperTools
        /usr/bin/install -o root -g wheel -m 0755 "$source" "$target"
        temp="$(/usr/bin/mktemp /tmp/netbar-sudoers.XXXXXX)"
        trap '/bin/rm -f "$temp"' EXIT
        /usr/bin/printf '%s ALL=(root) NOPASSWD: %s *\n' "$account" "$target" > "$temp"
        /usr/sbin/chown root:wheel "$temp"
        /bin/chmod 0440 "$temp"
        /usr/sbin/visudo -cf "$temp" >/dev/null
        /usr/bin/install -o root -g wheel -m 0440 "$temp" "$sudoers"
        /usr/sbin/visudo -cf "$sudoers" >/dev/null
        /usr/sbin/visudo -c >/dev/null
        /usr/bin/xattr -d com.apple.quarantine "$target" 2>/dev/null || true
        """#
        try runAdministratorShell(
            script: script,
            arguments: [source.path, Self.installedHelperPath, Self.sudoersPath, username]
        )
        guard state == .ready else {
            throw NetworkError.commandFailed("权限助手已安装，但免密码验证未通过。请点击“修复权限”重试。")
        }
    }

    func removeConfiguration() throws {
        let script = #"""
        set -eu
        /bin/rm -f "$1" "$2"
        """#
        try runAdministratorShell(script: script, arguments: [Self.installedHelperPath, Self.sudoersPath])
    }

    func run(_ arguments: [String]) throws {
        guard state == .ready else {
            throw NetworkError.privilegedAccessRequired
        }
        // `-n` explicitly forbids sudo from prompting. After one-time setup this
        // succeeds; if the configuration is damaged, the app reports repair is
        // needed instead of unexpectedly asking for another password.
        _ = try CommandRunner.run("/usr/bin/sudo", ["-n", Self.installedHelperPath] + arguments)
    }

    private func hasSafeOwnership(path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        let writableByNonRoot = info.st_mode & (S_IWGRP | S_IWOTH) != 0
        return info.st_uid == 0 && !writableByNonRoot
    }

    private func runAdministratorShell(script: String, arguments: [String]) throws {
        let appleScript = """
        on run argv
            set fixedScript to item 1 of argv
            set commandText to "/bin/sh -c " & quoted form of fixedScript & " netbar-installer"
            repeat with argumentIndex from 2 to count of argv
                set commandText to commandText & " " & quoted form of item argumentIndex of argv
            end repeat
            do shell script commandText with administrator privileges
        end run
        """
        _ = try CommandRunner.run("/usr/bin/osascript", ["-e", appleScript, script] + arguments)
    }
}

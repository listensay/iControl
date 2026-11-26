import Foundation
import CryptoKit

public enum InstallationStep: String, Sendable {
    case ssh = "连接 iPad 的 SSH 服务"
    case environment = "读取越狱环境"
    case verifyPackage = "校验官方安装包"
    case upload = "传输安装文件"
    case configure = "安装并配置控制端"
    case updateFPS = "更新 iPad 的 FPS 控制端"
    case verifyService = "验证 USB 控制服务"
    case restore = "恢复安装前的配置"
}

public struct InstallationResult: Sendable {
    public let environment: InstallationEnvironment
    public let serviceResponding: Bool
    public let fpsServiceResponding: Bool
    public let serverOutput: String
}

private final class SSHSession {
    private let forwarder: USBForwarder
    private let broker: AskpassServer
    private let credentials: SSHCredentials
    private let executable: URL
    private let knownHosts: URL
    private let alias: String
    private let cancellation: CancellationToken?

    init(mux: USBMux, device: USBDevice, credentials: SSHCredentials, helper: URL, supportDirectory: URL,
         cancellation: CancellationToken?) throws {
        self.credentials = credentials; self.executable = helper; self.cancellation = cancellation
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        knownHosts = supportDirectory.appendingPathComponent("known_hosts")
        if !FileManager.default.fileExists(atPath: knownHosts.path) {
            _ = FileManager.default.createFile(atPath: knownHosts.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        alias = SSHTrust.alias(for: device.udid)
        let port = try mux.sshPort(device: device)
        forwarder = try USBForwarder(mux: mux, device: device, devicePort: port, preferredPort: 0)
        do { broker = try AskpassServer(password: credentials.password) }
        catch { forwarder.stop(); throw error }
    }

    func stop() { broker.stop(); forwarder.stop() }
    deinit { stop() }

    func run(_ command: String, input: Data = Data(), timeout: TimeInterval = 30) throws -> ProcessResult {
        try cancellation?.check()
        let configPath = knownHosts.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let options = [
            "HostKeyAlias=\(alias)", "UserKnownHostsFile=\"\(configPath)\"", "GlobalKnownHostsFile=/dev/null",
            "StrictHostKeyChecking=accept-new", "ConnectTimeout=8", "ConnectionAttempts=1",
            "ServerAliveInterval=5", "ServerAliveCountMax=2", "NumberOfPasswordPrompts=1",
            "PreferredAuthentications=password,keyboard-interactive", "PubkeyAuthentication=no", "IdentityAgent=none",
            "LogLevel=ERROR", "ClearAllForwardings=yes", "EscapeChar=none"
        ]
        var arguments = ["-F", "/dev/null", "-T", "-p", String(forwarder.localPort)]
        for option in options { arguments += ["-o", option] }
        arguments += ["\(credentials.username)@127.0.0.1", command]
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = executable.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = "icontrol"
        environment["ICONTROL_ASKPASS"] = "1"
        environment["ICONTROL_ASKPASS_SOCKET"] = broker.path
        environment["ICONTROL_ASKPASS_TOKEN"] = broker.token
        environment["LC_ALL"] = "C"
        let result = try ProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: arguments,
                                           environment: environment, input: input, timeout: timeout, cancellation: cancellation)
        guard result.status == 0 else {
            let detail = (result.errorText + "\n" + result.outputText).trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || detail.contains("Host key verification failed") {
                throw ControlError("iPad 的 SSH 主机密钥发生了变化。请核对是否重新越狱或重装过 OpenSSH；诊断说明中有重置信任的方法。")
            }
            if detail.contains("Permission denied") || detail.contains("incorrect password") || detail.contains("Sorry, try again") {
                throw ControlError("SSH 登录或管理员密码不正确。请检查 iPad 的账户和密码。")
            }
            if detail.contains("not in the sudoers") || detail.contains("not allowed to execute") {
                throw ControlError("这个 iPad 账户没有安装权限。请使用 root 或具有 sudo 权限的账户。")
            }
            let lines = detail.components(separatedBy: .newlines).suffix(10).joined(separator: "\n")
            throw ControlError("iPad 操作失败（\(result.status)）：\n\(lines.prefix(2500))")
        }
        return result
    }

    func upload(_ bytes: Data, to path: String) throws {
        _ = try run("umask 077; cat > \(shellQuote(path))", input: bytes, timeout: 90)
    }
}

public struct USBInstaller: Sendable {
    public let mux: USBMux
    public let helper: URL
    public let packages: URL
    public let supportDirectory: URL
    public init(mux: USBMux = USBMux(), helper: URL, packages: URL, supportDirectory: URL) {
        self.mux = mux; self.helper = helper; self.packages = packages; self.supportDirectory = supportDirectory
    }

    private func current(_ device: USBDevice) throws -> USBDevice {
        guard let connected = try mux.devices().first(where: { $0.udid == device.udid }) else {
            throw ControlError("iPad 的 USB 数据连接尚未就绪。请解锁、信任这台 Mac，并检查数据线。")
        }
        var result = device; result = USBDevice(deviceID: connected.deviceID, udid: device.udid, name: device.name,
                                               productType: device.productType, version: device.version)
        return result
    }

    public func inspect(device: USBDevice, credentials: SSHCredentials, cancellation: CancellationToken? = nil,
                        progress: @Sendable (InstallationStep) -> Void = { _ in }) throws -> InstallationEnvironment {
        progress(.ssh)
        let session = try SSHSession(mux: mux, device: current(device), credentials: credentials,
                                     helper: helper, supportDirectory: supportDirectory, cancellation: cancellation)
        defer { session.stop() }
        progress(.environment)
        return try environment(on: session)
    }

    private func environment(on session: SSHSession) throws -> InstallationEnvironment {
        let output = try session.run("\(RemoteScripts.pathEnvironment); exec sh -s", input: Data(RemoteScripts.inspect.utf8))
        return try InstallationEnvironment.parse(output.outputText)
    }

    public func install(device: USBDevice, credentials: SSHCredentials, password: String, fpsToken: String? = nil,
                        scale: Double = 0.65, framesPerSecond: Int = 30, cancellation: CancellationToken? = nil,
                        progress: @Sendable (InstallationStep) -> Void = { _ in }) throws -> InstallationResult {
        let config = try ServerConfiguration.plist(password: password, scale: scale, framesPerSecond: framesPerSecond)
        progress(.ssh)
        let session = try SSHSession(mux: mux, device: current(device), credentials: credentials,
                                     helper: helper, supportDirectory: supportDirectory, cancellation: cancellation)
        defer { session.stop() }
        progress(.environment)
        let environment = try self.environment(on: session)
        guard environment.canInstall else { throw ControlError(environment.requirements.joined(separator: "\n")) }
        progress(.verifyPackage)
        let package = ServerPackage.forEnvironment(environment)
        let bytes = try package.verifiedData(in: packages)
        var fpsBytes: Data?
        if let fpsToken {
            _ = try FPSAccessToken.bytes(fpsToken)
            fpsBytes = try FPSDaemonPackage.verifiedData(in: packages.deletingLastPathComponent())
        }
        let stage = "/private/var/tmp/icontrol-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        _ = try session.run("umask 077; mkdir \(shellQuote(stage))")
        defer { _ = try? session.run("rm -rf -- \(shellQuote(stage))", timeout: 10) }
        progress(.upload)
        try session.upload(bytes, to: stage + "/server.deb")
        try session.upload(config, to: stage + "/Managed.plist")
        try session.upload(Data(RemoteScripts.configure.utf8), to: stage + "/configure.sh")
        try session.upload(Data(RemoteFPSScripts.functions.utf8), to: stage + "/fps-functions.sh")
        if let fpsBytes, let fpsToken {
            try session.upload(fpsBytes, to: stage + "/icontrol-fpsd")
            try session.upload(Data(fpsToken.utf8), to: stage + "/fps-token")
            let digest = SHA256.hash(data: fpsBytes).map { String(format: "%02x", $0) }.joined()
            try session.upload(Data(digest.utf8), to: stage + "/fps-sha256")
            try session.upload(FPSDaemonPackage.launchPlist(prefix: environment.prefix), to: stage + "/FPSDaemon.plist")
        }
        progress(.configure)
        let command = administratorCommand(script: stage + "/configure.sh", arguments: [stage, package.architecture, package.sha256, "install"], environment: environment)
        let input = administratorInput(credentials: credentials, environment: environment)
        let result = try session.run(command, input: input, timeout: 240)
        guard result.outputText.components(separatedBy: .newlines).contains("ICONTROL:DONE=installed") else {
            throw ControlError("控制端没有返回安装完成标识。请重新检测环境后检查安装状态。")
        }
        progress(.verifyService)
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        var responding = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            try cancellation?.check()
            do { _ = try mux.vncGreeting(device: current(device)); responding = true; break } catch { }
            Thread.sleep(forTimeInterval: 0.5)
        }
        var fpsResponding = false
        if fpsToken != nil {
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while ProcessInfo.processInfo.systemUptime < deadline {
                try cancellation?.check()
                do {
                    let link = try FPSUSBLink.connect(mux: mux, device: current(device), token: fpsToken!)
                    link.stop(); fpsResponding = true; break
                } catch { }
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        return InstallationResult(environment: environment, serviceResponding: responding,
                                  fpsServiceResponding: fpsResponding, serverOutput: result.outputText)
    }

    public func updateFPS(device: USBDevice, credentials: SSHCredentials,
                          progress: @Sendable (InstallationStep) -> Void = { _ in }) throws {
        progress(.ssh)
        let session = try SSHSession(mux: mux, device: current(device), credentials: credentials,
                                     helper: helper, supportDirectory: supportDirectory, cancellation: nil)
        defer { session.stop() }
        progress(.environment)
        let environment = try self.environment(on: session)
        guard environment.managedByIControl, environment.canInstall else { throw ControlError("仅能更新已由 iControl 管理的 iPad；请先检测环境并确认安装权限。") }
        progress(.verifyPackage)
        let bytes = try FPSDaemonPackage.verifiedData(in: packages.deletingLastPathComponent())
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let stage = "/private/var/tmp/icontrol-" + UUID().uuidString.lowercased()
        _ = try session.run("umask 077; mkdir \(shellQuote(stage))")
        defer { _ = try? session.run("rm -rf -- \(shellQuote(stage))", timeout: 10) }
        progress(.upload)
        try session.upload(bytes, to: stage + "/icontrol-fpsd")
        try session.upload(Data(RemoteScripts.configure.utf8), to: stage + "/configure.sh")
        try session.upload(Data(RemoteFPSScripts.functions.utf8), to: stage + "/fps-functions.sh")
        progress(.updateFPS)
        let result = try session.run(administratorCommand(script: stage + "/configure.sh", arguments: [stage, environment.architecture, digest, "update-fps"], environment: environment),
                                     input: administratorInput(credentials: credentials, environment: environment), timeout: 60)
        guard result.outputText.components(separatedBy: .newlines).contains("ICONTROL:DONE=fps-updated") else {
            throw ControlError("未收到 FPS 更新完成标识，请重新检测设备。")
        }
    }

    public func restore(device: USBDevice, credentials: SSHCredentials, cancellation: CancellationToken? = nil,
                        progress: @Sendable (InstallationStep) -> Void = { _ in }) throws {
        progress(.ssh)
        let session = try SSHSession(mux: mux, device: current(device), credentials: credentials,
                                     helper: helper, supportDirectory: supportDirectory, cancellation: cancellation)
        defer { session.stop() }
        let environment = try self.environment(on: session)
        guard environment.managedByIControl, environment.userID == 0 || environment.hasSudo else {
            throw ControlError("这台 iPad 没有可恢复的 iControl 配置，或当前账户没有管理员权限。")
        }
        let stage = "/private/var/tmp/icontrol-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        _ = try session.run("umask 077; mkdir \(shellQuote(stage))")
        defer { _ = try? session.run("rm -rf -- \(shellQuote(stage))", timeout: 10) }
        try session.upload(Data(RemoteScripts.configure.utf8), to: stage + "/configure.sh")
        try session.upload(Data(RemoteFPSScripts.functions.utf8), to: stage + "/fps-functions.sh")
        progress(.restore)
        _ = try session.run(administratorCommand(script: stage + "/configure.sh", arguments: [stage, environment.architecture, "", "restore"], environment: environment),
                            input: administratorInput(credentials: credentials, environment: environment), timeout: 45)
    }

    private func administratorCommand(script: String, arguments: [String], environment: InstallationEnvironment) -> String {
        let invocation = "sh " + ([script] + arguments).map(shellQuote).joined(separator: " ")
        let prefix = environment.userID == 0 ? "" : (environment.sudoWithoutPassword ? "sudo -n -- " : "sudo -S -p '' -- ")
        return "\(RemoteScripts.pathEnvironment); exec \(prefix)\(invocation)"
    }
    private func administratorInput(credentials: SSHCredentials, environment: InstallationEnvironment) -> Data {
        environment.userID != 0 && !environment.sudoWithoutPassword ? Data((credentials.administratorPassword + "\n").utf8) : Data()
    }
}

public enum RemoteScripts {
    public static let pathEnvironment = "PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/usr/sbin:/bin:/sbin; export PATH"
    public static let inspect = #"""
    set -eu
    PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/usr/sbin:/bin:/sbin
    export PATH
    PREFIX=''
    if [ -x /var/jb/usr/bin/dpkg ]; then DPKG=/var/jb/usr/bin/dpkg; PREFIX=/var/jb
    elif command -v dpkg >/dev/null 2>&1; then DPKG=$(command -v dpkg)
    else echo '没有找到越狱包管理器 dpkg。请先完成越狱。' >&2; exit 21; fi
    QUERY="${DPKG%/*}/dpkg-query"
    ARCH=$("$DPKG" --print-architecture)
    FW=$("$QUERY" -W -f='${Version}' firmware 2>/dev/null || true)
    PL=$("$QUERY" -W -f='${Status}' preferenceloader 2>/dev/null || true)
    INSTALLED=$("$QUERY" -W -f='${Version}' com.82flex.trollvnc 2>/dev/null || true)
    SUDO=0; SUDO_NOPASS=0; PREFERENCELOADER=0; SUPPORTED=0; MANAGED=0
    if command -v sudo >/dev/null 2>&1; then SUDO=1; fi
    if [ "$SUDO" = 1 ] && [ "$(sudo -n id -u 2>/dev/null || true)" = 0 ]; then SUDO_NOPASS=1; fi
    if [ "$PL" = 'install ok installed' ]; then PREFERENCELOADER=1; fi
    if [ -n "$FW" ] && "$DPKG" --compare-versions "$FW" ge 14.0; then SUPPORTED=1; fi
    if [ -f /var/mobile/Library/iControl/managed-by-icontrol ]; then MANAGED=1; fi
    printf 'ICONTROL:ARCH=%s\nICONTROL:PREFIX=%s\nICONTROL:FIRMWARE=%s\nICONTROL:UID=%s\n' "$ARCH" "$PREFIX" "$FW" "$(id -u)"
    printf 'ICONTROL:SUDO=%s\nICONTROL:SUDO_NOPASS=%s\nICONTROL:PREFERENCELOADER=%s\n' "$SUDO" "$SUDO_NOPASS" "$PREFERENCELOADER"
    printf 'ICONTROL:FIRMWARE_SUPPORTED=%s\nICONTROL:INSTALLED=%s\nICONTROL:MANAGED=%s\n' "$SUPPORTED" "$INSTALLED" "$MANAGED"
    """#

    public static let configure = #"""
    set -eu
    PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/usr/sbin:/bin:/sbin
    export PATH
    STAGE=$1; EXPECTED=$2; EXPECTED_HASH=$3; ACTION=$4
    [ "$(id -u)" = 0 ] || { echo '安装需要管理员权限。' >&2; exit 22; }
    PREFIX=''
    if [ -x /var/jb/usr/bin/dpkg ]; then DPKG=/var/jb/usr/bin/dpkg; PREFIX=/var/jb
    else DPKG=$(command -v dpkg); fi
    QUERY="${DPKG%/*}/dpkg-query"
    [ "$("$DPKG" --print-architecture)" = "$EXPECTED" ] || { echo '越狱架构已变化，停止安装。' >&2; exit 23; }
    case "$EXPECTED:$PREFIX" in iphoneos-arm64:/var/jb|iphoneos-arm:) ;; *) exit 24 ;; esac
    RES="$PREFIX/Library/PreferenceBundles/TrollVNCPrefs.bundle"
    CFG="$RES/Managed.plist"
    DAEMON="$PREFIX/Library/LaunchDaemons/com.82flex.trollvnc.plist"
    STATE=/var/mobile/Library/iControl
    fps_prepare_install() { :; }; fps_prepare_restore() { :; }; fps_rollback() { :; }
    fps_install() { :; }; fps_commit() { :; }; fps_restore_original() { :; }; fps_restore_commit() { :; }
    if [ -f "$STAGE/fps-functions.sh" ]; then . "$STAGE/fps-functions.sh"; fi
    stop_service() {
      launchctl bootout system/com.82flex.trollvnc >/dev/null 2>&1 || launchctl unload "$DAEMON" >/dev/null 2>&1 || true
    }
    start_service() {
      launchctl enable system/com.82flex.trollvnc >/dev/null 2>&1 || true
      launchctl bootstrap system "$DAEMON" >/dev/null 2>&1 || launchctl load -w "$DAEMON"
      launchctl kickstart -k system/com.82flex.trollvnc >/dev/null 2>&1 || true
    }
    if [ "$ACTION" = update-fps ]; then
      [ -f "$STATE/fps-managed-by-icontrol" ] && [ -x "$FPS_BIN" ] && [ -f "$FPS_JOB" ] &&
        launchctl print system/com.icontrol.fpsd | grep -Eq '^[[:space:]]*pid = [1-9][0-9]*[[:space:]]*$' || {
        echo '未找到正在运行的受管 FPS 控制端，未修改设备。' >&2; exit 46;
      }
      if command -v sha256sum >/dev/null 2>&1; then SUM=$(sha256sum "$STAGE/icontrol-fpsd")
      elif command -v shasum >/dev/null 2>&1; then SUM=$(shasum -a 256 "$STAGE/icontrol-fpsd")
      else echo 'iPad 上没有 SHA256 校验工具，未修改设备。' >&2; exit 44; fi
      [ "${SUM%% *}" = "$EXPECTED_HASH" ] || { echo 'FPS 控制端传输校验失败。' >&2; exit 44; }
      cp "$FPS_BIN" "$STAGE/fps.previous"
      rollback_fps_update() {
        CODE=$?; trap - EXIT HUP INT TERM
        fps_stop
        fps_copy_or_remove "$STAGE/fps.previous" "$FPS_BIN" 755
        fps_start
        echo '更新失败，已换回原 FPS 控制端。' >&2; exit "$CODE"
      }
      trap rollback_fps_update EXIT
      trap 'exit 130' HUP INT TERM
      fps_stop
      fps_copy_or_remove "$STAGE/icontrol-fpsd" "$FPS_BIN" 755
      "$FPS_BIN" --version
      fps_start
      ATTEMPT=0
      until launchctl print system/com.icontrol.fpsd | grep -Eq '^[[:space:]]*pid = [1-9][0-9]*[[:space:]]*$'; do
        ATTEMPT=$((ATTEMPT+1)); [ "$ATTEMPT" -lt 12 ] || exit 47; sleep 1
      done
      trap - EXIT HUP INT TERM
      echo 'ICONTROL:DONE=fps-updated'; exit 0
    fi
    if [ "$ACTION" = restore ]; then
      [ -f "$STATE/managed-by-icontrol" ] || { echo '没有 iControl 配置备份。' >&2; exit 25; }
      grep -q ICONTROLConfiguration "$CFG" || { echo '配置已被其他软件修改，停止恢复。' >&2; exit 26; }
      [ -f "$STATE/Managed.original.plist" ] || [ -f "$STATE/Managed.original.absent" ] || { echo '配置备份不完整。' >&2; exit 27; }
      cp "$CFG" "$STAGE/Managed.restore-before.plist"
      fps_prepare_restore
      restore_failed() {
        CODE=$?; trap - EXIT HUP INT TERM
        stop_service
        cp "$STAGE/Managed.restore-before.plist" "$CFG"; chown mobile:mobile "$CFG"; chmod 600 "$CFG"
        start_service || true
        fps_rollback || true
        exit "$CODE"
      }
      trap restore_failed EXIT
      trap 'exit 130' HUP INT TERM
      stop_service
      if [ -f "$STATE/Managed.original.plist" ]; then
        cp "$STATE/Managed.original.plist" "$CFG"; chown mobile:mobile "$CFG"; chmod 600 "$CFG"
      elif [ -f "$STATE/Managed.original.absent" ]; then rm -f "$CFG"
      fi
      start_service
      fps_restore_original
      fps_restore_commit
      rm -f "$STATE/managed-by-icontrol"
      trap - EXIT HUP INT TERM
      echo 'ICONTROL:DONE=restored'
      exit 0
    fi
    [ "$ACTION" = install ] || exit 28
    [ "$("$QUERY" -W -f='${Status}' preferenceloader 2>/dev/null || true)" = 'install ok installed' ] || { echo '请先安装 PreferenceLoader。' >&2; exit 29; }
    FW=$("$QUERY" -W -f='${Version}' firmware 2>/dev/null || true)
    "$DPKG" --compare-versions "$FW" ge 14.0 || exit 30
    if command -v sha256sum >/dev/null 2>&1; then ACTUAL=$(sha256sum "$STAGE/server.deb"); ACTUAL=${ACTUAL%% *}
    elif command -v shasum >/dev/null 2>&1; then ACTUAL=$(shasum -a 256 "$STAGE/server.deb"); ACTUAL=${ACTUAL%% *}
    else ACTUAL=$EXPECTED_HASH; fi
    [ "$ACTUAL" = "$EXPECTED_HASH" ] || { echo '传输后的安装包校验失败。' >&2; exit 31; }
    HAD_CONFIG=0; WAS_RUNNING=0; COMMITTED=0
    if [ -f "$CFG" ]; then cp "$CFG" "$STAGE/Managed.before.plist"; HAD_CONFIG=1; fi
    if launchctl print system/com.82flex.trollvnc >/dev/null 2>&1; then WAS_RUNNING=1; fi
    fps_prepare_install
    rollback() {
      CODE=$?
      trap - EXIT HUP INT TERM
      if [ "$COMMITTED" != 1 ]; then
        stop_service
        if [ "$HAD_CONFIG" = 1 ]; then cp "$STAGE/Managed.before.plist" "$CFG"; chown mobile:mobile "$CFG"; chmod 600 "$CFG"
        else rm -f "$CFG"; fi
        if [ "$WAS_RUNNING" = 1 ] && [ -f "$DAEMON" ]; then start_service || true; fi
        fps_rollback || true
        echo '配置未完成，已恢复此前的受管配置。请重新检测安装状态。' >&2
      fi
      exit "$CODE"
    }
    trap rollback EXIT
    trap 'exit 130' HUP INT TERM
    stop_service
    mkdir -p "$RES"
    chmod 755 "$RES"
    cp "$STAGE/Managed.plist" "$CFG.new"
    chown mobile:mobile "$CFG.new"; chmod 600 "$CFG.new"
    mv -f "$CFG.new" "$CFG"
    INSTALLED=$("$QUERY" -W -f='${Version}' com.82flex.trollvnc 2>/dev/null || true)
    if [ -z "$INSTALLED" ] || "$DPKG" --compare-versions "$INSTALLED" lt 3.2-272; then
      "$DPKG" -i "$STAGE/server.deb"
    else echo '已有同版或更高版本，直接配置控制服务。'; fi
    [ -x "$PREFIX/usr/bin/trollvncserver" ] && [ -f "$DAEMON" ] || { echo '控制端安装文件不完整。' >&2; exit 32; }
    stop_service
    start_service
    fps_install
    mkdir -p "$STATE"; chown root:mobile "$STATE"; chmod 750 "$STATE"
    if [ ! -f "$STATE/managed-by-icontrol" ]; then
      rm -f "$STATE/Managed.original.plist" "$STATE/Managed.original.absent"
      if [ "$HAD_CONFIG" = 1 ]; then cp "$STAGE/Managed.before.plist" "$STATE/Managed.original.plist"; chmod 600 "$STATE/Managed.original.plist"
      else touch "$STATE/Managed.original.absent"; chmod 600 "$STATE/Managed.original.absent"; fi
    fi
    fps_commit
    printf 'iControl configuration v1\n' > "$STATE/managed-by-icontrol"
    chmod 644 "$STATE/managed-by-icontrol"
    COMMITTED=1
    echo 'ICONTROL:DONE=installed'
    """#
}

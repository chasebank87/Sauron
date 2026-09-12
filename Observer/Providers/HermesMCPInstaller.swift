import AppKit
import Foundation

enum HermesMCPInstaller {
    enum Method: String, Sendable {
        case desktop
        case cli
    }

    struct InstallResult: Sendable {
        var message: String
        var method: Method
        var alreadyConfigured: Bool
    }

    enum InstallError: LocalizedError {
        case hermesNotFound
        case pythonNotFound
        case deeplinkFailed
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .hermesNotFound:
                "Hermes CLI not found on PATH. Install Hermes, then try again."
            case .pythonNotFound:
                "Could not locate Hermes’s bundled Python."
            case .deeplinkFailed:
                "Found Hermes desktop, but couldn’t open the install link."
            case .failed(let message):
                message
            }
        }
    }

    /// Prefer Hermes desktop deep link when the app is present; otherwise install via CLI.
    static func installObserverMemory(endpoint: URL, token: String) throws -> InstallResult {
        if isDesktopAppInstalled() {
            guard let url = installDeepLink(endpoint: endpoint, token: token) else {
                throw InstallError.failed("Could not build Hermes MCP install link.")
            }
            let opened = NSWorkspace.shared.open(url)
            guard opened else { throw InstallError.deeplinkFailed }
            return InstallResult(
                message: "Opened Hermes desktop — confirm “observer” MCP install there. Keep Observer running afterward.",
                method: .desktop,
                alreadyConfigured: false
            )
        }

        return try installViaCLI(endpoint: endpoint, token: token)
    }

    /// True when the real Hermes desktop bundle is present or `hermes://` is registered to it.
    static func isDesktopAppInstalled() -> Bool {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.nousresearch.hermes"),
           FileManager.default.fileExists(atPath: app.path) {
            return true
        }
        if let handler = urlHandlerForHermesScheme(), looksLikeHermesDesktop(handler) {
            return true
        }
        return desktopReleaseAppURLs().contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func installDeepLink(endpoint: URL, token: String) -> URL? {
        let config: [String: Any] = [
            "url": endpoint.absoluteString,
            "headers": [
                "Authorization": "Bearer \(token)"
            ],
            "enabled": true
        ]
        guard JSONSerialization.isValidJSONObject(config),
              let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        else { return nil }
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        var components = URLComponents()
        components.scheme = "hermes"
        components.host = "mcp"
        components.path = "/install"
        components.queryItems = [
            URLQueryItem(name: "name", value: "observer"),
            URLQueryItem(name: "config", value: encoded)
        ]
        return components.url
    }

    /// Writes `mcp_servers.observer` into `~/.hermes/config.yaml` and stores the bearer token in `~/.hermes/.env`.
    static func installViaCLI(endpoint: URL, token: String) throws -> InstallResult {
        let hermes = resolveHermesExecutable()
        guard hermes != nil || resolveHermesPython() != nil else {
            throw InstallError.hermesNotFound
        }
        guard let python = resolveHermesPython() else {
            throw InstallError.pythonNotFound
        }

        let script = """
        import json, sys
        from hermes_cli.mcp_config import _get_mcp_servers, _save_bearer_auth_token, _save_mcp_server

        endpoint = sys.argv[1]
        token = sys.argv[2]
        existing = _get_mcp_servers().get("observer") or {}
        already = bool(existing.get("url") == endpoint)
        headers = _save_bearer_auth_token("observer", token)
        ok = _save_mcp_server("observer", {
            "url": endpoint,
            "headers": headers,
            "enabled": True,
        })
        if not ok:
            print(json.dumps({"ok": False, "error": "Hermes rejected the MCP config."}))
            raise SystemExit(2)
        print(json.dumps({"ok": True, "already": already, "env_key": "MCP_OBSERVER_API_KEY"}))
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", script, endpoint.absoluteString, token]
        var env = ProcessInfo.processInfo.environment
        if env["HOME"] == nil {
            env["HOME"] = NSHomeDirectory()
        }
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outText = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            let detail = [errText, outText].filter { !$0.isEmpty }.joined(separator: "\n")
            throw InstallError.failed(detail.isEmpty ? "Hermes install failed (exit \(process.terminationStatus))." : detail)
        }

        struct Payload: Decodable {
            var ok: Bool
            var already: Bool?
            var error: String?
        }
        guard let data = outText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.ok
        else {
            throw InstallError.failed(errText.isEmpty ? outText : errText)
        }

        let host = endpoint.host ?? "127.0.0.1"
        let port = endpoint.port.map(String.init) ?? "8787"
        let message = payload.already == true
            ? "Updated Hermes CLI MCP “observer” → \(host):\(port) — token refreshed in ~/.hermes/.env. Run /reload-mcp or restart Hermes."
            : "Installed Observer Memory into Hermes CLI as MCP “observer”. Restart Hermes or run /reload-mcp, then keep Observer running."
        return InstallResult(message: message, method: .cli, alreadyConfigured: payload.already == true)
    }

    // MARK: - Desktop detection

    private static func urlHandlerForHermesScheme() -> URL? {
        guard let probe = URL(string: "hermes://mcp/install") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    private static func looksLikeHermesDesktop(_ appURL: URL) -> Bool {
        let name = appURL.deletingPathExtension().lastPathComponent.lowercased()
        if let bundle = Bundle(url: appURL) {
            let bid = (bundle.bundleIdentifier ?? "").lowercased()
            if bid == "com.nousresearch.hermes" { return true }
            if bid.contains("hermes") && !bid.contains(".setup") { return true }
            let display = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "").lowercased()
            if display.contains("hermes") && !bid.contains(".setup") { return true }
        }
        return name.contains("hermes") && !name.contains("setup")
    }

    private static func desktopReleaseAppURLs() -> [URL] {
        let home = NSHomeDirectory()
        return ["mac-arm64", "mac", "mac-x64"].map { arch in
            URL(fileURLWithPath: "\(home)/.hermes/hermes-agent/apps/desktop/release/\(arch)/Hermes.app")
        }
    }

    // MARK: - CLI resolution

    static func resolveHermesExecutable() -> String? {
        which("hermes")
    }

    static func resolveHermesPython() -> String? {
        if let hermes = resolveHermesExecutable(),
           let script = try? String(contentsOfFile: hermes, encoding: .utf8) {
            if let match = script.range(of: #"HERMES_PYTHON="([^"]+)""#, options: .regularExpression) {
                let line = String(script[match])
                if let open = line.firstIndex(of: "\""),
                   let close = line.lastIndex(of: "\""),
                   open < close {
                    let path = String(line[line.index(after: open)..<close])
                    if FileManager.default.isExecutableFile(atPath: path) {
                        return path
                    }
                }
            }
        }
        if let cellarPython = latestHomebrewHermesPython() {
            return cellarPython
        }
        let venv = "\(NSHomeDirectory())/.hermes/hermes-agent/.venv/bin/python3"
        if FileManager.default.isExecutableFile(atPath: venv) {
            return venv
        }
        return which("python3")
    }

    private static func latestHomebrewHermesPython() -> String? {
        let roots = [
            "/opt/homebrew/Cellar/hermes-agent",
            "/usr/local/Cellar/hermes-agent"
        ]
        let fm = FileManager.default
        for root in roots {
            guard let versions = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for version in versions.sorted().reversed() {
                let path = "\(root)/\(version)/libexec/bin/python3"
                if fm.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }
}

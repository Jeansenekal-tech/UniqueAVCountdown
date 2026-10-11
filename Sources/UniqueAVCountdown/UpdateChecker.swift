import AppKit
import Foundation

/// Checks the GitHub repo's latest release and offers to download a newer version.
/// The repo is set in Info.plist under "UpdateGitHubRepo" (e.g. "jeansenekal/UniqueAVCountdown").
/// The repo must be public, because the app checks without logging in.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var lastResult = "Not checked yet"
    @Published private(set) var isChecking = false

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var repo: String? {
        guard let r = Bundle.main.infoDictionary?["UpdateGitHubRepo"] as? String,
              r.contains("/"), !r.uppercased().contains("YOUR-") else { return nil }
        return r.trimmingCharacters(in: .whitespaces)
    }

    private var skippedVersion: String {
        get { UserDefaults.standard.string(forKey: "skippedUpdateVersion") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "skippedUpdateVersion") }
    }

    /// Called at launch: stays quiet unless there's a new version.
    func checkInBackground() {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await check(userInitiated: false)
        }
    }

    /// From the menu: always reports the result.
    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard !isChecking else { return }
        guard let repo = Self.repo else {
            lastResult = "Update checking isn't set up (no GitHub repo in Info.plist)"
            if userInitiated { inform("Updates aren't set up yet", lastResult + ". See the README, section “Updates”.") }
            return
        }
        isChecking = true
        defer { isChecking = false }

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("UniqueAVCountdown/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 {
                lastResult = "No releases published yet"
                if userInitiated { inform("No updates found", "No releases have been published on GitHub yet (or the repo is private).") }
                return
            }
            guard code == 200 else {
                lastResult = "Update check failed (HTTP \(code))"
                if userInitiated { inform("Couldn't check for updates", lastResult) }
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = Self.clean(release.tag_name)
            lastResult = "Checked \(Self.timeString()) — latest is \(latest)"

            guard Self.isNewer(latest, than: Self.currentVersion) else {
                if userInitiated {
                    inform("You're up to date", "Unique AV Countdown \(Self.currentVersion) is the latest version.")
                }
                return
            }
            if !userInitiated && latest == skippedVersion { return }
            offer(release, version: latest)
        } catch {
            lastResult = "Update check failed: \(error.localizedDescription)"
            if userInitiated { inform("Couldn't check for updates", error.localizedDescription) }
        }
    }

    private func offer(_ release: Release, version: String) {
        let alert = NSAlert()
        alert.messageText = "Unique AV Countdown \(version) is available"
        var notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 700 { notes = String(notes.prefix(700)) + "…" }
        alert.informativeText = "You have version \(Self.currentVersion)."
            + (notes.isEmpty ? "" : "\n\nWhat's new:\n\(notes)")
            + "\n\nTo install: download it, quit this app, and drag the new app into Applications (replace the old one)."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let asset = release.assets.first { $0.name.lowercased().hasSuffix(".zip") }
                ?? release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            if let link = URL(string: asset?.browser_download_url ?? release.html_url) {
                NSWorkspace.shared.open(link)
            }
        case .alertThirdButtonReturn:
            skippedVersion = version
        default:
            break
        }
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: Version helpers

    static func clean(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("v") { t.removeFirst() }
        return t
    }

    /// Compares "1.2.10" style versions number by number.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func timeString() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: Date())
    }
}

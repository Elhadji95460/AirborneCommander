import Foundation
import AppKit
import Observation

// MARK: - GardienBridge : pont Airborne Commander ↔ serveur Gardien local
//
// Gardien tourne en Python sur :8765 (surveillance, tunnel Cloudflare, caméra).
// Airborne Commander n'embarque PAS le serveur : il le pilote / surveille.
//
// Lecture :
//   • GET  /api/gardien/status
//   • GET  /api/gardien/surveillance/status
//   • GET  /api/gardien/remote (URL tunnel)
//   • fichier ~/data/gardien_remote/url.txt
//
// Actions :
//   • POST /api/gardien/surveillance/camera/wake  (ouvrir_app → Gardien.app)
//   • ouvrir Gardien.app / le journal

@MainActor
@Observable
final class GardienBridge {

    static let shared = GardienBridge()

    /// Port du serveur Gardien (Flask).
    static let port = 8765

    var online = false
    var arme = false
    var cameraActive = false
    var aFrame = false
    var etat = "—"
    var remoteURL: String = ""
    var lastError: String?
    var lastRefresh: Date?
    var alertCount = 0
    var statusLine: String = "Recherche de Gardien…"

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var engine: FleetEngine?

    private var baseLocal: String { "http://127.0.0.1:\(Self.port)" }

    func attach(engine: FleetEngine) {
        self.engine = engine
        startPolling()
        refresh()
    }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Lecture état

    func refresh() {
        Task {
            await refreshAsync()
        }
    }

    private func refreshAsync() async {
        // 1) Ping status
        guard let status = await getJSON("\(baseLocal)/api/gardien/status") else {
            online = false
            statusLine = "Gardien hors ligne (serveur :8765)"
            lastError = "Serveur local injoignable"
            return
        }
        online = true
        lastError = nil

        // 2) Surveillance
        if let surv = await getJSON("\(baseLocal)/api/gardien/surveillance/status") {
            arme = surv["arme"] as? Bool ?? false
            cameraActive = surv["camera_active"] as? Bool ?? false
            aFrame = surv["a_frame"] as? Bool ?? false
            etat = (surv["etat"] as? String) ?? "—"
            if let n = surv["derniere_alerte_id"] as? Int {
                alertCount = n
            }
        }

        // 3) URL distante (API puis fichier)
        if let rem = await getJSON("\(baseLocal)/api/gardien/remote") {
            if let u = rem["url"] as? String, u.hasPrefix("http") {
                remoteURL = u
            }
        }
        if remoteURL.isEmpty {
            remoteURL = Self.readURLFile() ?? ""
        }

        lastRefresh = Date()
        statusLine = buildStatusLine()
    }

    private func buildStatusLine() -> String {
        var parts: [String] = []
        parts.append(online ? "en ligne" : "hors ligne")
        if arme { parts.append("ARMÉ") } else { parts.append("désarmé") }
        if cameraActive { parts.append("caméra ON") }
        else if aFrame { parts.append("dernière image") }
        else { parts.append("caméra off") }
        parts.append(etat)
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    /// Réveille la caméra native (ouvre Gardien.app si besoin).
    func wakeCamera(openApp: Bool = true) {
        Task {
            let body: [String: Any] = [
                "duree_sec": 3600,
                "auto_armer": true,
                "ouvrir_app": openApp,
                "ouvrir_fenetre": false,
            ]
            let ok = await postJSON(
                "\(baseLocal)/api/gardien/surveillance/camera/wake",
                body: body
            )
            if ok {
                engine?.log("🛡 Gardien — caméra réveillée"
                    + (openApp ? " (app Mac)" : ""))
            } else {
                engine?.log("🛡 Gardien — échec réveil caméra")
            }
            await refreshAsync()
        }
    }

    /// Arme la surveillance (sans code). Le DÉSARMEMENT reste strictement humain.
    func armSurveillance() {
        Task {
            let ok = await postJSON(
                "\(baseLocal)/api/gardien/surveillance/armer",
                body: [:]
            )
            if ok {
                engine?.log("🛡 Gardien — surveillance ARMÉE (ordre IA)")
            } else {
                engine?.log("🛡 Gardien — échec armement (code déjà requis ou serveur)")
            }
            await refreshAsync()
        }
    }

    /// Refus explicite si l'IA tente de désarmer.
    func refuseAIDisarm() {
        engine?.log("🛡 BLOQUÉ — le désarmement / code est réservé à Elhadji (humain).")
    }

    /// Ouvre l'app Gardien Mac (capture native).
    func openGardienApp() {
        let candidates = [
            NSHomeDirectory() + "/Desktop/Gardien/Gardien.app",
            "/Applications/Gardien.app",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                engine?.log("🛡 Ouverture de Gardien.app")
                return
            }
        }
        // Bundle id de secours
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.radarlink.GardienMac"
        ) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            engine?.log("🛡 Ouverture de Gardien (bundle id)")
            return
        }
        engine?.log("🛡 Gardien.app introuvable")
    }

    /// Copie l'URL distante dans le presse-papiers (pour l'iPhone).
    func copyRemoteURL() {
        let u = remoteURL.isEmpty ? (Self.readURLFile() ?? "") : remoteURL
        guard !u.isEmpty else {
            engine?.log("🛡 Pas d'URL tunnel disponible")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(u, forType: .string)
        engine?.log("🛡 URL tunnel copiée : \(u)")
    }

    /// Ouvre l'URL distante dans le navigateur (test).
    func openRemoteInBrowser() {
        let u = remoteURL.isEmpty ? (Self.readURLFile() ?? "") : remoteURL
        guard let url = URL(string: u) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Fichiers locaux

    static func readURLFile() -> String? {
        let path = NSHomeDirectory() + "/data/gardien_remote/url.txt"
        guard let t = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let u = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return u.hasPrefix("http") ? u : nil
    }

    // MARK: - HTTP

    private func getJSON(_ urlString: String) async -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.5
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private func postJSON(_ urlString: String, body: [String: Any]) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 5
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

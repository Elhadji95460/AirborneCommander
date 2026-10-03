import Foundation
import Observation
import AppKit

// MARK: - MasterS1Bridge : pont Airborne Commander ↔ DJI RoboMaster S1
//
// Protocole texte SDK S1 (Wi‑Fi Direct, IP par défaut 192.168.2.1) :
//   commande TCP 40923  — chassis / gimbal / blaster / led / battery
//   (vidéo 40921 et events 40925 optionnels plus tard)
//
// Architecture : un thread de commande (queue) + polling batterie.
// L'UI ne parle jamais au socket directement.

@MainActor
@Observable
final class MasterS1Bridge {

    static let shared = MasterS1Bridge()
    static let defaultIP = "192.168.2.1"
    static let cmdPort: UInt16 = 40923

    var unit = GroundUnit()
    var lastLog = ""

    @ObservationIgnored private weak var engine: FleetEngine?
    @ObservationIgnored private var client: S1SocketClient?
    @ObservationIgnored private var cmdQueue = DispatchQueue(label: "com.airborne.masters1.cmd")
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var connecting = false

    func attach(engine: FleetEngine) {
        self.engine = engine
        // Unité par défaut déjà présente dans engine.groundUnits
    }

    // MARK: - Connexion

    func connect(ip: String? = nil) {
        let target = (ip?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? unit.ip
        unit.ip = target
        unit.state = .connecting
        unit.statusDetail = "Connexion \(target):\(Self.cmdPort)…"
        engine?.log("🤖 Master S1 — connexion \(target)…")
        connecting = true

        cmdQueue.async { [weak self] in
            guard let self else { return }
            do {
                let c = try S1SocketClient(ip: target, port: Self.cmdPort)
                try c.enterSDK()
                Task { @MainActor in
                    self.client = c
                    self.connecting = false
                    self.unit.state = .ready
                    self.unit.statusDetail = "SDK OK — \(target)"
                    self.unit.lastSeen = Date()
                    self.engine?.log("🤖 Master S1 connecté (\(target))")
                    self.startPolling()
                    // Mode libre + LED d'identification
                    self.enqueue("robot mode free")
                    self.enqueue("led control comp all r 0 g 255 b 80 effect solid")
                }
            } catch {
                Task { @MainActor in
                    self.connecting = false
                    self.unit.state = .error
                    self.unit.statusDetail = error.localizedDescription
                    self.engine?.log("🤖 Master S1 — échec : \(error.localizedDescription)")
                }
            }
        }
    }

    func disconnect() {
        stopPolling()
        emergencyStop()
        cmdQueue.async { [weak self] in
            self?.client?.close()
            Task { @MainActor in
                self?.client = nil
                self?.unit.state = .offline
                self?.unit.statusDetail = "Déconnecté"
                self?.unit.battery = nil
                self?.engine?.log("🤖 Master S1 déconnecté")
            }
        }
    }

    // MARK: - Commandes

    /// x,y m/s (-3.5…3.5), z deg/s (-600…600)
    func chassis(x: Double, y: Double, z: Double) {
        guard unit.connected else { return }
        let cx = max(-3.5, min(3.5, x))
        let cy = max(-3.5, min(3.5, y))
        let cz = max(-600, min(600, z))
        enqueue(String(format: "chassis speed x %.2f y %.2f z %.1f", cx, cy, cz))
        if abs(cx) + abs(cy) + abs(cz) > 0.01 {
            unit.state = .moving
        } else if unit.state == .moving {
            unit.state = .ready
        }
    }

    func stopChassis() {
        chassis(x: 0, y: 0, z: 0)
    }

    func gimbal(pitchSpeed: Double, yawSpeed: Double) {
        guard unit.connected else { return }
        let p = max(-450, min(450, pitchSpeed))
        let y = max(-450, min(450, yawSpeed))
        enqueue(String(format: "gimbal speed p %.1f y %.1f", p, y))
    }

    func gimbalRecenter() {
        enqueue("gimbal recenter")
    }

    func fire() {
        enqueue("blaster fire")
        engine?.log("🤖 Master S1 — FIRE")
    }

    func setMode(_ mode: GroundRobotMode) {
        unit.robotMode = mode
        enqueue("robot mode \(mode.rawValue)")
        engine?.log("🤖 Master S1 — mode \(mode.label)")
    }

    func setLED(r: Int, g: Int, b: Int, effect: String = "solid") {
        enqueue("led control comp all r \(r) g \(g) b \(b) effect \(effect)")
    }

    func emergencyStop() {
        // Arrêt immédiat châssis + gimbal
        cmdQueue.async { [weak self] in
            guard let self, let c = self.client else { return }
            _ = try? c.send("chassis speed x 0 y 0 z 0")
            _ = try? c.send("gimbal speed p 0 y 0")
        }
        unit.state = unit.connected ? .emergency : .offline
        unit.statusDetail = "⛔ STOP d'urgence"
        engine?.log("🤖 Master S1 — ⛔ EMERGENCY STOP")
        // Revenir prêt après un court instant si toujours connecté
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            if self?.unit.connected == true, self?.unit.state == .emergency {
                self?.unit.state = .ready
                self?.unit.statusDetail = "Prêt (après stop)"
            }
        }
    }

    /// Patrol simple avant / arrière (démo terrestre).
    func patrolDemo() {
        guard unit.connected else {
            engine?.log("🤖 Master S1 hors ligne — connecte d'abord")
            return
        }
        engine?.log("🤖 Master S1 — patrouille démo")
        chassis(x: 0.4, y: 0, z: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.chassis(x: -0.4, y: 0, z: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            self?.stopChassis()
            self?.gimbalRecenter()
        }
    }

    /// Ouvre l'app desktop RoboMaster S1 Commander si installée.
    func openControllerApp() {
        let paths = [
            NSHomeDirectory() + "/Desktop/RoboMaster S1 Commander.app",
            "/Applications/RoboMaster S1 Commander.app",
        ]
        for p in paths where FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
            engine?.log("🤖 Ouverture RoboMaster S1 Commander")
            return
        }
        // Projet Python
        let py = NSHomeDirectory() + "/RoboMasterS1Controller/main.py"
        if FileManager.default.fileExists(atPath: py) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = [
                "-lc",
                "cd ~/RoboMasterS1Controller && source .venv/bin/activate 2>/dev/null; python3 main.py &",
            ]
            try? task.run()
            engine?.log("🤖 Lancement RoboMasterS1Controller (Python)")
            return
        }
        engine?.log("🤖 App RoboMaster S1 introuvable")
    }

    // MARK: - Internals

    private func enqueue(_ cmd: String) {
        cmdQueue.async { [weak self] in
            guard let self, let c = self.client else { return }
            do {
                let resp = try c.send(cmd)
                if !resp.lowercased().contains("ok") && !cmd.contains("?") {
                    Task { @MainActor in
                        self.lastLog = "S1: \(cmd) → \(resp)"
                    }
                }
            } catch {
                Task { @MainActor in
                    self.unit.state = .error
                    self.unit.statusDetail = error.localizedDescription
                    self.engine?.log("🤖 S1 erreur : \(error.localizedDescription)")
                }
            }
        }
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollBattery()
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollBattery() {
        cmdQueue.async { [weak self] in
            guard let self, let c = self.client else { return }
            do {
                let resp = try c.send("robot battery ?")
                // Réponse typique : "ok 72" ou juste un nombre
                let digits = resp.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
                if let pct = digits.first {
                    Task { @MainActor in
                        self.unit.battery = max(0, min(100, pct))
                        self.unit.lastSeen = Date()
                        if self.unit.state == .ready || self.unit.state == .moving {
                            self.unit.statusDetail = "OK · batterie \(pct) %"
                        }
                    }
                }
            } catch {
                // ignore poll errors légers
            }
        }
    }
}

// MARK: - Client TCP protocole texte S1

final class S1SocketClient {
    private let ip: String
    private let port: UInt16
    private var fd: Int32 = -1

    init(ip: String, port: UInt16) throws {
        self.ip = ip
        self.port = port
        try connect()
    }

    private func connect() throws {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        let err = getaddrinfo(ip, portStr, &hints, &result)
        guard err == 0, let info = result else {
            throw NSError(domain: "MasterS1", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Adresse \(ip) invalide"])
        }
        defer { freeaddrinfo(info) }

        let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard sock >= 0 else {
            throw NSError(domain: "MasterS1", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Socket impossible"])
        }

        // Timeout 3 s
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let rc = Darwin.connect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen)
        guard rc == 0 else {
            Darwin.close(sock)
            throw NSError(domain: "MasterS1", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Connexion refusée \(ip):\(port) — Mac sur Wi‑Fi RoboMaster ?"])
        }
        fd = sock
    }

    func enterSDK() throws {
        let r = try send("command")
        if !r.lowercased().contains("ok") {
            throw NSError(domain: "MasterS1", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "SDK non confirmé (\(r))"])
        }
    }

    @discardableResult
    func send(_ text: String) throws -> String {
        guard fd >= 0 else {
            throw NSError(domain: "MasterS1", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Non connecté"])
        }
        var payload = (text.trimmingCharacters(in: .whitespacesAndNewlines) + ";")
            .data(using: .utf8) ?? Data()
        let sent = payload.withUnsafeBytes { buf -> Int in
            guard let base = buf.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return Darwin.send(fd, base, payload.count, 0)
        }
        guard sent > 0 else {
            throw NSError(domain: "MasterS1", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Envoi échoué"])
        }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let n = Darwin.recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else {
            throw NSError(domain: "MasterS1", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "Pas de réponse robot"])
        }
        return String(bytes: buffer[0..<n], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func close() {
        if fd >= 0 {
            _ = try? send("quit")
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}

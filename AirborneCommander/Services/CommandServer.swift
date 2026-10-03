import Foundation
import Network
import Observation

// MARK: - CommandServer : serveur WebSocket du poste de commandement
//
// Écoute en ws://IP-du-Mac:5570 sur toutes les interfaces. Chaque iPhone-relais
// s'y connecte en WiFi, annonce ses drones (hello), pousse leur télémétrie, et
// exécute les commandes reçues (décollage, atterrissage, pcmd, LED, photo…).
//
// Même vocabulaire JSON que fleet_server.py (l'ancien serveur Python, TCP) —
// seule la couche de transport change : WebSocket natif via Network.framework.
@Observable
final class CommandServer {

    static let port: UInt16 = 5570

    var listening = false
    var phoneCount: Int { clients.count }
    var localIP: String = CommandServer.findLocalIP()

    @ObservationIgnored private weak var engine: FleetEngine?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var clients: [String: NWConnection] = [:]
    @ObservationIgnored private var droneToPhone: [String: String] = [:]

    init(engine: FleetEngine) {
        self.engine = engine
        start()
    }

    // MARK: Démarrage -----------------------------------------------------------

    func start() {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        do {
            let l = try NWListener(using: params,
                                   on: NWEndpoint.Port(rawValue: Self.port)!)
            listener = l
            // Publie un service Bonjour : les iPhones-relais trouvent alors le
            // Mac tout seuls sur le réseau, sans qu'on saisisse d'IP (mDNS).
            let macName = Host.current().localizedName ?? "Airborne Commander"
            l.service = NWListener.Service(name: macName,
                                           type: "_airbornecmd._tcp")
            l.serviceRegistrationUpdateHandler = { [weak self] change in
                if case .add = change {
                    Task { @MainActor in
                        self?.engine?.log("📣 Service Bonjour publié "
                            + "(\(macName)) — les iPhones peuvent trouver le "
                            + "Mac automatiquement.")
                    }
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.listening = (state == .ready)
                    if state == .ready {
                        self?.engine?.log("📡 Serveur WebSocket prêt : "
                            + "ws://\(self?.localIP ?? "?"):\(Self.port)")
                    }
                }
            }
            l.start(queue: .main)
        } catch {
            let desc = error.localizedDescription
            Task { @MainActor in
                self.engine?.log("⛔ Serveur WebSocket : \(desc)")
            }
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(on: conn, phone: nil)
    }

    // MARK: Réception -------------------------------------------------------------

    private func receive(on conn: NWConnection, phone: String?) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            var phone = phone
            if let data,
               let msg = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] {
                phone = self.handle(msg, from: conn, phone: phone)
            }
            if error == nil {
                self.receive(on: conn, phone: phone)
            } else if let phone {
                Task { @MainActor in self.phoneLeft(phone) }
            }
        }
    }

    /// Traite un message d'iPhone ; retourne l'identifiant du téléphone.
    private func handle(_ msg: [String: Any], from conn: NWConnection,
                        phone: String?) -> String? {
        var phone = phone
        Task { @MainActor in
            guard let engine = self.engine else { return }
            switch msg["type"] as? String {
            case "hello":
                let name = msg["phone"] as? String ?? "iPhone"
                phone = name
                self.clients[name] = conn
                // Inventaire des manettes (pour le handover + affichage)
                let relay: PhoneRelay
                if let p = engine.phones.first(where: { $0.name == name }) {
                    relay = p
                } else {
                    relay = PhoneRelay(name: name)
                    engine.phones.append(relay)
                }
                relay.connected = true
                relay.lastSeen = Date()
                relay.version = msg["version"] as? String
                relay.ios = msg["ios"] as? String
                engine.log("📱 \(name) — app v\(relay.version ?? "?") · "
                    + "iOS \(relay.ios ?? "?")")
                // Enregistre les drones annoncés par ce téléphone —
                // « drones » (liste) ou « drone » (chaîne, app Drone Flotte)
                var bleNames = msg["drones"] as? [String] ?? []
                if bleNames.isEmpty, let single = msg["drone"] as? String {
                    bleNames = [single]
                }
                for ble in bleNames {
                    if let existant = engine.drones.first(where: {
                        $0.bleName == ble }) {
                        // Drone déjà connu : mise à jour du porteur — c'est
                        // aussi la bascule finale du HANDOVER.
                        if existant.phone != name {
                            engine.log("↔︎ \(existant.name) est maintenant "
                                + "tenu par \(name) (avant : "
                                + "\(existant.phone ?? "?")).")
                            existant.phone = name
                        }
                        continue
                    }
                    let id = "drone-\(String(format: "%02d", engine.drones.count + 1))"
                    let d = Drone(id: id, name: "Drone \(String(format: "%02d", engine.drones.count + 1))")
                    d.bleName = ble
                    d.phone = name
                    // Préférence mémorisée : retour image par drone
                    d.photoReturnEnabled = !UserDefaults.standard
                        .bool(forKey: "photoOff.\(ble)")
                    engine.drones.append(d)
                    engine.restoreConfig(for: d)   // groupe + mode mémorisés
                    self.droneToPhone[d.id] = name
                }
                engine.log("📱 \(name) connecté "
                    + "(\(bleNames.count) drone(s)).")
                // welcome : id = label du drone si unique (l'app Drone Flotte
                // l'affiche comme « vous êtes Drone 01 »), sinon le téléphone
                let welcomeID = bleNames.count == 1
                    ? (engine.drones.first { $0.bleName == bleNames[0] }?.name
                       ?? name)
                    : name
                self.reply(conn, ["type": "welcome", "id": welcomeID])
            case "telemetry":
                guard let id = msg["drone"] as? String,
                      let d = engine.drone(id: id)
                        ?? engine.drones.first(where: { $0.bleName == id })
                else { return }
                if let b = msg["battery"] as? Int { d.battery = b }
                if let a = msg["altitude"] as? Double { d.altitude = a }
                if let dist = msg["distance"] as? Double { d.distance = dist }
                if let s = msg["signal"] as? String,
                   let sig = BTSignal(rawValue: s) { d.signal = sig }
                // Compat app Drone Flotte : « link » (ok/faible/perdu) → signal
                if let l = msg["link"] as? String {
                    d.signal = l == "ok" ? .fort
                             : l == "faible" ? .faible : .perdu
                }
                if let st = msg["state"] as? String,
                   let fs = FlightState(rawValue: st) { d.state = fs }
                if let r = msg["rssi"] as? Int { d.rssi = r }
                d.lastSeen = Date()
            case "photo":
                // Retour image : photo rapatriée du drone par le téléphone
                guard let id = msg["drone"] as? String,
                      let d = engine.drones.first(where: { $0.bleName == id }),
                      let b64 = msg["jpeg_b64"] as? String,
                      let jpeg = Data(base64Encoded: b64) else { return }
                d.lastPhoto = jpeg
                d.lastPhotoName = msg["name"] as? String
                d.lastPhotoDate = Date()
                engine.log("📷 Retour image de \(d.name) : "
                    + "\(d.lastPhotoName ?? "photo") "
                    + "(\(jpeg.count / 1024) Ko).")
                // Sauvegarde sur le Bureau (dossier « Airborne Commander - Photos »)
                engine.persistPhoto(jpeg, for: d, name: d.lastPhotoName)
                // 🧠 L'IA analyse la vraie photo : le verdict nourrit la
                // mémoire de flotte et oriente les prochaines missions.
                engine.analyzePhoto(for: d, secteur: d.lastSector)
            case "scout_result":
                // Réponse d'enchère du handover
                engine.handoverScoutResult(
                    phone: msg["phone"] as? String ?? phone ?? "?",
                    drone: msg["drone"] as? String ?? "?",
                    rssi: msg["rssi"] as? Int)
            case "event":
                engine.log("📱 \(msg["msg"] as? String ?? "")")
            default:
                break
            }
        }
        return phone ?? (msg["phone"] as? String)
    }

    /// Envoi direct à une manette (handover : release/scout/acquire).
    func send(toPhone phone: String, _ msg: [String: Any]) {
        guard let conn = clients[phone] else {
            Task { @MainActor in
                self.engine?.log("⚠️ \(phone) injoignable pour "
                    + "\(msg["action"] as? String ?? "commande").")
            }
            return
        }
        reply(conn, msg)
    }

    @MainActor
    private func phoneLeft(_ phone: String) {
        clients[phone] = nil
        engine?.phones.first(where: { $0.name == phone })?.connected = false
        engine?.log("📱 \(phone) déconnecté — ses drones passent en "
                    + "« liaison perdue ».")
        for d in engine?.drones ?? [] where d.phone == phone {
            d.state = .linkLost
            d.signal = .perdu
        }
        // Reprise automatique par un autre téléphone (le drone n'étant plus
        // tenu, il ré-émet ses annonces BLE et peut être capté ailleurs).
        engine?.recoverOrphanedDrones(previousPhone: phone)
    }

    // MARK: Envoi --------------------------------------------------------------------

    func send(to drone: Drone, _ msg: [String: Any]) {
        guard !drone.isSimulated else { return }
        guard let phone = drone.phone, let conn = clients[phone] else {
            // Échec VISIBLE : sinon les commandes se perdent en silence.
            Task { @MainActor in
                self.engine?.log("⚠️ Commande pour \(drone.name) perdue : son "
                    + "téléphone (\(drone.phone ?? "?")) n'est pas connecté "
                    + "au serveur.")
            }
            return
        }
        reply(conn, msg)
    }

    private func reply(_ conn: NWConnection, _ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj)
        else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "msg",
                                              metadata: [meta])
        conn.send(content: data, contentContext: ctx,
                  completion: .contentProcessed { _ in })
    }

    // MARK: IP locale -------------------------------------------------------------------

    static func findLocalIP() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                  let name = String(validatingUTF8: ifa.ifa_name),
                  name == "en0" || name == "en1" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            address = String(cString: host)
            break
        }
        return address
    }
}

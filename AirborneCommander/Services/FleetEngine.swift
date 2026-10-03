import Foundation
import Observation
import AppKit

// MARK: - FleetEngine : l'intelligence centrale de la V5
//
// Tient l'état de la flotte, applique les règles :
//  • un drone appartient à UN seul groupe ;
//  • « Lancer Groupe X » = décollage SÉQUENTIEL (01 puis 02 puis 03…), et la
//    mission ne démarre — pour tous EN MÊME TEMPS — que quand le dernier a
//    confirmé son décollage ;
//  • passage en Manuel possible à tout instant (manette PS5) : le drone sort
//    temporairement de la logique du groupe ; retour IA/Semi-IA = il rentre ;
//  • sécurité batterie héritée des versions précédentes : < 25 % = URGENCE,
//    Manuel refusé, atterrissage prioritaire.
@MainActor
@Observable
final class FleetEngine {

    static let shared = FleetEngine()

    var drones: [Drone] = []
    var phones: [PhoneRelay] = []       // les manettes connues (handover)
    var groups: [DroneGroup] = [DroneGroup(id: "A"), DroneGroup(id: "B"),
                                DroneGroup(id: "C"), DroneGroup(id: "D")]
    /// Unités terrestres (RoboMaster S1, etc.)
    var groundUnits: [GroundUnit] = []
    /// Drone actuellement piloté à la manette (mode Manuel)
    var manualTarget: Drone?
    /// Dernières consignes des sticks (affichées dans la barre latérale)
    var lastManualInput = "—"
    var journal: [String] = []

    /// Environnement de vol courant (intérieur/extérieur) — pilote les
    /// paramètres de mission de l'IA. Persisté.
    var environment: FlightEnvironment =
        FlightEnvironment(rawValue:
            UserDefaults.standard.string(forKey: "flightEnvironment") ?? "")
        ?? .interieur {
        didSet {
            UserDefaults.standard.set(environment.rawValue,
                                      forKey: "flightEnvironment")
            neural.observe(sector: nil, environment: environment.rawValue,
                           battery: nil)
            log("🌐 Environnement : \(environment.rawValue). \(environment.hint)")
        }
    }

    /// Cerveau IA optionnel (API Claude). Sans clé → IA locale seule.
    @ObservationIgnored let brain = ClaudeBrain.shared
    /// Réseau de neurones local : réflexes appris par renforcement.
    @ObservationIgnored let neural = NeuralMemory.shared
    /// Vision GPU (Metal) — PRÉPARÉE mais NON connectée (voir GPUVision).
    @ObservationIgnored let gpuVision = GPUVision.shared
    /// Pont vers le serveur Gardien local (surveillance / tunnel / caméra).
    @ObservationIgnored let gardien = GardienBridge.shared
    /// Pont vers le robot terrestre RoboMaster S1 (Master S1).
    @ObservationIgnored let masterS1 = MasterS1Bridge.shared

    @ObservationIgnored private var lastNoTargetHint = Date.distantPast
    @ObservationIgnored private var lastZeroSent = Date.distantPast
    @ObservationIgnored private var missions: [String: Task<Void, Never>] = [:]

    @ObservationIgnored lazy var server = CommandServer(engine: self)
    @ObservationIgnored private var simTimer: Timer?

    // Handover : seuils et état des enchères
    static let handoverRSSIThreshold = -80     // dBm
    static let handoverStreak = 3              // mesures consécutives (~6 s)
    @ObservationIgnored private var scoutResults: [String: [String: Int]] = [:]
    @ObservationIgnored private var handoverTimer: Timer?
    /// Dernière tentative de reprise par drone (throttle de la récupération).
    @ObservationIgnored private var lastRecovery: [String: Date] = [:]

    private init() {
        // Le cerveau Claude journalise dans le même journal que la flotte.
        brain.onLog = { [weak self] msg in self?.log(msg) }
        // Évolution du réseau (neurogenèse / élagage) → journal persistant.
        neural.onEvent = { [weak self] msg in self?.learn(msg) }
        // Apprentissage : restaure la mémoire des vols précédents.
        loadMemory()
        log("🧬 \(NeuralMemory.regleOr)")
        // Vision GPU prête mais débranchée (aucune décision ne l'utilise).
        if gpuVision.ready {
            log("🖥️ Vision GPU prête (\(gpuVision.deviceName)) — NON connectée "
                + "(VisionAI + Claude restent aux commandes).")
        }
        // Module sécurité Gardien (serveur Python :8765)
        gardien.attach(engine: self)
        log("🛡 Module Gardien branché — surveillance locale :8765")
        // Module terrestre Master S1 (RoboMaster)
        masterS1.attach(engine: self)
        if !groundUnits.contains(where: { $0.id == masterS1.unit.id }) {
            groundUnits.append(masterS1.unit)
        }
        log("🤖 Module terrestre Master S1 prêt (Wi‑Fi Direct 192.168.2.1)")
        // Surveillance continue du signal de chaque drone (toutes les 2 s)
        handoverTimer = Timer.scheduledTimer(withTimeInterval: 2,
                                             repeats: true) { _ in
            Task { @MainActor in FleetEngine.shared.handoverTick() }
        }
    }

    // MARK: - HANDOVER automatique entre iPhones -------------------------------
    //
    // Contrainte BLE : un drone CONNECTÉ n'émet plus d'annonces — impossible
    // de mesurer son signal depuis un autre iPhone tant qu'il est tenu.
    // Stratégie « enchère après libération » :
    //   signal < seuil (3 mesures) → release → les candidats sondent 3 s →
    //   le meilleur RSSI gagne → acquire → bascule (re-hello) — sinon retour
    //   à l'iPhone d'origine. Pendant la fenêtre (~4-8 s), le drone en vol
    //   reste en STATIONNAIRE (failsafe du firmware quand le PCMD s'arrête).

    private func handoverTick() {
        // Drones SIMULÉS : même logique, transfert joué entre les deux
        // iPhones factices (démo visuelle du mécanisme complet).
        for d in drones where d.handover == .none && d.isSimulated {
            guard let rssi = d.rssi else { continue }
            if rssi <= Self.handoverRSSIThreshold {
                d.lowSignalStreak += 1
            } else {
                d.lowSignalStreak = 0
            }
            if d.lowSignalStreak >= Self.handoverStreak { simHandover(d) }
        }
        for d in drones where d.handover == .none && !d.isSimulated {
            guard let rssi = d.rssi, d.phone != nil,
                  d.state != .linkLost else { continue }
            if rssi <= Self.handoverRSSIThreshold {
                d.lowSignalStreak += 1
                if d.lowSignalStreak == 1 {
                    log("📶 \(d.name) : signal faible (\(rssi) dBm) — "
                        + "surveillance renforcée.")
                }
            } else {
                d.lowSignalStreak = 0
            }
            if d.lowSignalStreak >= Self.handoverStreak {
                startHandover(d)
            }
        }
        // Récupération CONTINUE : un drone dont le téléphone a disparu est
        // repris par un autre téléphone dès qu'il est de nouveau capté.
        recoverySweep()
    }

    // MARK: - RÉCUPÉRATION : un drone a perdu son téléphone -----------------------
    //
    // Différent du handover (signal faible, téléphone encore là) : ici le
    // téléphone qui tenait le drone a DISPARU (app fermée, WiFi coupé, hors
    // de portée du Mac). Le drone, plus tenu par personne, se remet à émettre
    // ses annonces BLE → un AUTRE téléphone connecté le sonde et le reprend.
    // Le drone en vol reste en stationnaire (failsafe firmware) pendant la
    // bascule. Balayé en continu par handoverTick pour réessayer tant qu'il
    // n'est pas repris.

    private func recoverySweep() {
        for d in drones where d.handover == .none && !d.isSimulated
            && d.state == .linkLost {
            // Le téléphone qui le tenait est-il vraiment parti ? (sinon c'est
            // sa reconnexion locale qui doit gagner, pas un autre téléphone.)
            let holder = d.phone.flatMap { name in
                phones.first { $0.name == name } }
            let holderGone = (holder == nil) || (holder?.connected == false)
            guard holderGone else { continue }
            let key = d.bleName ?? d.id
            guard Date().timeIntervalSince(lastRecovery[key] ?? .distantPast) > 15
            else { continue }
            let candidats = availableCandidates(excluding: d.phone)
            guard !candidats.isEmpty else { continue }
            lastRecovery[key] = Date()
            Task { await runRecovery(d, candidats: candidats) }
        }
    }

    /// Téléphones connectés pouvant reprendre un drone (place libre, ≠ celui
    /// qui l'a perdu).
    private func availableCandidates(excluding phone: String?) -> [String] {
        phones.filter { p in
            p.connected && p.name != phone
                && drones.filter { $0.phone == p.name
                                   && $0.state != .linkLost }.count < 2
        }.map(\.name)
    }

    /// Appelé quand un téléphone se déconnecte du Mac : ses drones sont
    /// aussitôt proposés à la reprise par les autres téléphones.
    func recoverOrphanedDrones(previousPhone: String) {
        let orphans = drones.filter { $0.phone == previousPhone
                                      && !$0.isSimulated }
        guard !orphans.isEmpty else { return }
        log("🔁 \(previousPhone) déconnecté — reprise de \(orphans.count) "
            + "drone(s) par un autre téléphone…")
        for d in orphans where d.handover == .none {
            let candidats = availableCandidates(excluding: previousPhone)
            guard !candidats.isEmpty else {
                log("🔁 \(d.name) : aucun autre téléphone connecté pour le "
                    + "reprendre — réessai automatique dès qu'il y en a un.")
                continue
            }
            lastRecovery[d.bleName ?? d.id] = Date()
            Task { await runRecovery(d, candidats: candidats) }
        }
    }

    /// Enchère de reprise (sans libération : le drone émet déjà, son téléphone
    /// est parti).
    private func runRecovery(_ d: Drone, candidats: [String]) async {
        let clé = d.bleName ?? d.id
        d.handover = .scouting
        scoutResults[clé] = [:]
        log("🔁 Reprise de \(d.name) : sondage par "
            + "\(candidats.joined(separator: ", "))…")
        for c in candidats {
            server.send(toPhone: c, ["type": "command", "drone": clé,
                                     "action": "scout", "duration": 3])
        }
        try? await Task.sleep(for: .seconds(4.5))
        let enchères = scoutResults[clé] ?? [:]
        guard let (gagnant, rssi) = enchères.max(by: { $0.value < $1.value })
        else {
            log("🔁 ✗ \(d.name) : aucun téléphone ne le capte pour l'instant "
                + "— nouvel essai automatique plus tard.")
            d.handover = .none
            return
        }
        d.handover = .transferring(gagnant)
        log("🔁 \(d.name) : \(gagnant) le capte (\(rssi) dBm) — reprise du "
            + "relais…")
        server.send(toPhone: gagnant, ["type": "command", "drone": clé,
                                       "action": "acquire"])
        let limite = Date().addingTimeInterval(12)
        while Date() < limite {
            if d.phone == gagnant {          // re-hello reçu → bascule faite
                d.handover = .none
                d.rssi = rssi
                log("🔁 ✓ \(d.name) REPRIS par \(gagnant) — liaison rétablie.")
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        log("🔁 ✗ \(d.name) : \(gagnant) n'a pas confirmé — nouvel essai plus "
            + "tard.")
        d.handover = .none
    }

    func startHandover(_ d: Drone) {
        guard let ancien = d.phone else { return }
        d.lowSignalStreak = 0
        let candidats = phones.filter { p in
            p.connected && p.name != ancien
                && drones.filter { $0.phone == p.name }.count < 2
        }.map(\.name)
        guard !candidats.isEmpty else {
            log("↔︎ \(d.name) : signal \(d.rssi ?? 0) dBm sous le seuil, mais "
                + "aucun autre iPhone disponible — on reste sur \(ancien).")
            return
        }
        d.handover = .releasing
        log("↔︎ HANDOVER de \(d.name) : signal \(d.rssi ?? 0) dBm ≤ "
            + "\(Self.handoverRSSIThreshold) dBm — libération par \(ancien)…")
        let clé = d.bleName ?? d.id
        scoutResults[clé] = [:]
        server.send(toPhone: ancien,
                    ["type": "command", "drone": clé, "action": "release"])
        Task { await runHandover(d, ancien: ancien, candidats: candidats) }
    }

    private func runHandover(_ d: Drone, ancien: String,
                             candidats: [String]) async {
        let clé = d.bleName ?? d.id
        let début = Date()
        try? await Task.sleep(for: .seconds(1))   // le drone ré-émet
        d.handover = .scouting
        log("↔︎ \(d.name) : sondage par \(candidats.joined(separator: ", "))…")
        for c in candidats {
            server.send(toPhone: c, ["type": "command", "drone": clé,
                                     "action": "scout", "duration": 3])
        }
        try? await Task.sleep(for: .seconds(4.5))
        let enchères = scoutResults[clé] ?? [:]
        guard let (gagnant, rssi) = enchères.max(by: { $0.value < $1.value })
        else {
            log("↔︎ ✗ \(d.name) : aucun candidat ne capte le drone — retour "
                + "à \(ancien).")
            server.send(toPhone: ancien, ["type": "command", "drone": clé,
                                          "action": "acquire"])
            d.handover = .none
            return
        }
        d.handover = .transferring(gagnant)
        log("↔︎ \(d.name) : meilleur signal = \(gagnant) (\(rssi) dBm) — "
            + "prise de relais…")
        server.send(toPhone: gagnant, ["type": "command", "drone": clé,
                                       "action": "acquire"])
        // Attend la bascule (le re-hello du gagnant met d.phone à jour)
        let limite = Date().addingTimeInterval(12)
        while Date() < limite {
            if d.phone == gagnant {
                d.handover = .none
                d.rssi = rssi
                log(String(format: "↔︎ ✓ HANDOVER réussi : %@ est passé de "
                    + "%@ à %@ en %.1f s.", d.name, ancien, gagnant,
                    Date().timeIntervalSince(début)))
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        log("↔︎ ✗ \(d.name) : \(gagnant) n'a pas confirmé — retour à \(ancien).")
        server.send(toPhone: ancien, ["type": "command", "drone": clé,
                                      "action": "acquire"])
        d.handover = .none
    }

    // MARK: - IA d'analyse d'image : le sol vu par le drone guide les choix

    /// Mémoire de flotte : verdict par secteur (« nord » → « encombré »…),
    /// utilisée pour orienter les missions suivantes.
    @ObservationIgnored var sectorKnowledge: [String: String] = [:]

    /// Analyse la dernière photo d'un drone et enregistre le verdict.
    func analyzePhoto(for d: Drone, secteur: String?) {
        guard let jpeg = d.lastPhoto,
              let score = VisionAI.clutterScore(jpeg) else { return }
        d.groundScore = score
        let verdict = VisionAI.verdict(score: score)
        d.groundVerdict = verdict
        log(String(format: "🧠 Analyse image %@ : sol %@ (%.1f).",
                   d.name, verdict, score))
        if let s = secteur {
            sectorKnowledge[s] = verdict
            saveSectorKnowledge()
            if verdict == "encombré" {
                learn("🧠 Mémoire de flotte : secteur \(s) noté ENCOMBRÉ — "
                    + "évité aux prochaines missions.")
            }
        }
        // 🧠 Sur-cerveau optionnel : si l'API Claude est configurée, elle VOIT
        // la photo et affine le verdict local (obstacles nommés, action).
        if brain.enabled, let jpeg = d.lastPhoto {
            let env = environment.rawValue
            Task { await self.refineWithClaude(d, jpeg: jpeg,
                                               secteur: secteur, env: env) }
        }
    }

    /// Analyse la photo par l'API Claude et applique son verdict raisonné.
    /// L'IA locale reste le secours : si Claude échoue, rien n'est écrasé.
    private func refineWithClaude(_ d: Drone, jpeg: Data,
                                  secteur: String?, env: String) async {
        guard let a = await brain.analyzeGround(
            jpeg: jpeg, drone: d.name, environment: env,
            secteur: secteur, battery: d.battery) else { return }
        d.groundVerdict = a.verdict
        brain.lastAssessment = "\(d.name) · \(a.verdict) · \(a.action)"
        var msg = "🧠 Claude voit le sol de \(d.name) : \(a.verdict)"
        if !a.obstacles.isEmpty {
            msg += " (obstacles : \(a.obstacles.prefix(4).joined(separator: ", ")))"
        }
        msg += " → \(a.action)."
        if !a.raison.isEmpty { msg += " \(a.raison)" }
        learn(msg)
        if let s = secteur { sectorKnowledge[s] = a.verdict; saveSectorKnowledge() }
    }

    /// Ordre des secteurs pour les prochaines missions. Dès que le RÉSEAU DE
    /// NEURONES a appris (≥ 1 vol), c'est lui qui décide (poids appris) ;
    /// sinon on retombe sur l'heuristique « les encombrés en dernier ».
    func sectorsOrderedByKnowledge() -> [Int] {
        if neural.trainings > 0 {
            return neural.orderedSectors(environment: environment.rawValue)
        }
        let noms = ["nord", "est", "ouest", "sud"]
        return (0..<4).sorted { a, b in
            let ka = sectorKnowledge[noms[a]] == "encombré" ? 1 : 0
            let kb = sectorKnowledge[noms[b]] == "encombré" ? 1 : 0
            return ka == kb ? a < b : ka < kb
        }
    }

    /// Features neuronales d'un vol (secteur + environnement + niveau batterie).
    private func neuralFeatures(sector: String, env: String,
                                battery: Int?) -> Set<String> {
        var f: Set<String> = []
        let map = ["nord": "sect_nord", "est": "sect_est",
                   "ouest": "sect_ouest", "sud": "sect_sud"]
        if let k = map[sector] { f.insert(k) }
        f.insert(env == "Extérieur" ? "env_ext" : "env_int")
        f.insert((battery ?? 50) >= 50 ? "bat_haut" : "bat_bas")
        return f
    }

    func handoverScoutResult(phone: String, drone: String, rssi: Int?) {
        if let rssi { scoutResults[drone, default: [:]][phone] = rssi }
        log("↔︎ enchère \(phone) → \(drone) : "
            + (rssi.map { "\($0) dBm" } ?? "non capté"))
    }

    /// Handover joué pour les drones simulés (démo du mécanisme complet).
    private func simHandover(_ d: Drone) {
        guard let ancien = d.phone else { return }
        d.lowSignalStreak = 0
        let gagnant = ancien.contains("Alpha") ? "iPhone-11-Bravo"
                                               : "iPhone-11-Alpha"
        d.handover = .releasing
        log("↔︎ HANDOVER de \(d.name) : signal \(d.rssi ?? 0) dBm ≤ "
            + "\(Self.handoverRSSIThreshold) dBm — libération par \(ancien)…")
        Task {
            let début = Date()
            try? await Task.sleep(for: .seconds(1))
            d.handover = .scouting
            log("↔︎ \(d.name) : sondage par \(gagnant)…")
            try? await Task.sleep(for: .seconds(1.5))
            let rssi = Int.random(in: (-62)...(-52))
            log("↔︎ enchère \(gagnant) → \(d.bleName ?? d.id) : \(rssi) dBm")
            d.handover = .transferring(gagnant)
            log("↔︎ \(d.name) : meilleur signal = \(gagnant) (\(rssi) dBm) — "
                + "prise de relais…")
            try? await Task.sleep(for: .seconds(1.5))
            d.phone = gagnant
            d.rssi = rssi
            d.handover = .none
            log(String(format: "↔︎ ✓ HANDOVER réussi : %@ est passé de %@ à "
                + "%@ en %.1f s.", d.name, ancien, gagnant,
                Date().timeIntervalSince(début)))
        }
    }

    // MARK: - Composition -------------------------------------------------------

    func drone(id: String) -> Drone? { drones.first { $0.id == id } }

    func group(id: String?) -> DroneGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    func members(of g: DroneGroup) -> [Drone] {
        drones.filter { $0.groupID == g.id }.sorted { $0.name < $1.name }
    }

    var unassigned: [Drone] { drones.filter { $0.groupID == nil } }

    /// Assigne un drone à un groupe (un seul groupe par drone — l'ancien
    /// est remplacé). Refusé pendant une mission du groupe cible.
    func assign(_ d: Drone, to groupID: String?) {
        if let g = group(id: groupID), g.missionState != .idle {
            log("⚠️ \(g.name) est en mission — assignation de \(d.name) refusée.")
            return
        }
        d.groupID = groupID
        rememberConfig(d)
        log("\(d.name) → \(group(id: groupID)?.name ?? "sans groupe").")
    }

    // MARK: - Modes -------------------------------------------------------------

    func setMode(_ d: Drone, _ mode: DroneMode) {
        if mode == .manual, d.batteryEmergency {
            log("⛔ \(d.name) : batterie < 25 % — mode Manuel REFUSÉ, "
                + "atterrissage prioritaire.")
            return
        }
        d.mode = mode
        rememberConfig(d)
        switch mode {
        case .manual:
            d.inGroupLogic = false          // sort de la logique du groupe
            manualTarget = d
            missions[d.id]?.cancel()        // l'IA lâche ce drone
            log("🎮 \(d.name) passe en MANUEL (manette PS5) — hors groupe "
                + "temporairement.")
        case .ia:
            d.inGroupLogic = true
            if manualTarget === d { manualTarget = nil }
            // 🧠 Mode IA = le drone part en MISSION (l'exploration convenue :
            // photos, secteur attitré, économie batterie, retour, rapport).
            // Le secteur est choisi avec la mémoire d'analyse des images.
            let index = drones.firstIndex(where: { $0 === d }) ?? 0
            let ordre = sectorsOrderedByKnowledge()
            let secteur = ordre[index % ordre.count]
            if d.state == .grounded {
                log("🧠 \(d.name) : IA 100 % — décollage puis mission.")
                Task {
                    d.state = .takingOff
                    send(.takeOff, to: d)
                    if await waitAirborne(d, timeout: 8) {
                        d.state = .airborne
                        startMission(for: d, secteur: secteur)
                    } else {
                        d.state = .grounded
                        log("✗ \(d.name) : décollage non confirmé — mission "
                            + "annulée (Pilotage autorisé activé sur le "
                            + "téléphone ? batterie ?).")
                    }
                }
            } else if d.state == .airborne || d.state == .onMission {
                log("🧠 \(d.name) : IA 100 % — reprise de mission en vol.")
                startMission(for: d, secteur: secteur)
            }
        case .semi:
            d.inGroupLogic = true
            if manualTarget === d { manualTarget = nil }
            missions[d.id]?.cancel()
            log("\(d.name) en Semi-IA : trajectoire IA suspendue, corrections "
                + "manuelles admises.")
        }
        server.send(to: d, ["type": "command", "drone": d.bleName ?? d.id,
                            "action": "set_mode", "mode": mode.rawValue])
    }

    // MARK: - Lancement de groupe : décollage séquentiel --------------------------

    func launchGroup(_ g: DroneGroup) {
        guard g.missionState == .idle else { return }
        let squad = members(of: g).filter { $0.inGroupLogic
                                            && $0.state == .grounded }
        guard !squad.isEmpty else {
            log("\(g.name) : aucun drone prêt au sol.")
            return
        }
        g.missionState = .launching
        g.takeoffCount = squad.count
        g.takeoffIndex = 0
        log("🚀 \(g.name) : décollage séquentiel de \(squad.count) drone(s)…")

        Task {
            // 1) Décollages UN PAR UN, dans l'ordre des noms (01, 02, 03…)
            for (i, d) in squad.enumerated() {
                g.takeoffIndex = i + 1
                d.state = .takingOff
                log("  ↑ \(d.name) décolle (\(i + 1)/\(squad.count))…")
                send(.takeOff, to: d)
                let ok = await waitAirborne(d, timeout: 8)
                if ok {
                    d.state = .airborne
                    log("  ✓ \(d.name) en vol stationnaire.")
                } else {
                    d.state = .grounded
                    log("  ✗ \(d.name) n'a pas confirmé son décollage — exclu "
                        + "de la vague.")
                }
            }
            // 2) TOUS décollés → mission simultanée
            let airborne = squad.filter { $0.state == .airborne }
            guard !airborne.isEmpty else {
                g.missionState = .idle
                log("\(g.name) : échec du décollage, mission annulée.")
                return
            }
            // Secteurs choisis avec la MÉMOIRE de l'IA : les secteurs notés
            // « encombrés » (analyse des photos passées) passent en dernier.
            let ordre = sectorsOrderedByKnowledge()
            for (i, d) in airborne.enumerated() {
                d.state = .onMission
                send(.startMission, to: d)
                startMission(for: d, secteur: ordre[i % ordre.count])
            }
            g.missionState = .mission
            log("🎯 \(g.name) : mission lancée SIMULTANÉMENT pour "
                + "\(airborne.count) drone(s).")
        }
    }

    // MARK: - Mission IA : l'exploration convenue (photos, secteurs, batterie)

    private func startMission(for d: Drone, secteur: Int) {
        missions[d.id]?.cancel()
        missions[d.id] = Task { await self.runMission(d, secteur: secteur) }
    }

    /// Mission d'exploration d'UN drone — le scénario de nos simulations :
    /// stabilisation, photo au départ, avancée dans SON secteur, photo,
    /// retour base, atterrissage — avec la règle batterie < 25 % = on se pose.
    private func runMission(_ d: Drone, secteur: Int) async {
        let secteurs: [(roll: Int, pitch: Int, nom: String)] = [
            (0, 30, "nord"), (30, 0, "est"), (-30, 0, "ouest"), (0, -30, "sud"),
        ]
        let v = secteurs[secteur % secteurs.count]

        func actif() -> Bool {
            !Task.isCancelled && d.mode == .ia && d.inGroupLogic
                && d.state != .emergency && d.state != .linkLost
        }
        func poserSiBatterieCritique() -> Bool {
            guard d.batteryEmergency else { return false }
            log("⛔ \(d.name) : batterie < 25 % en mission — atterrissage "
                + "immédiat (règle de sécurité).")
            return true
        }
        func stop() { send(.pcmd(roll: 0, pitch: 0, yaw: 0, gaz: 0), to: d) }
        func atterrir() {
            stop()
            d.state = .landing
            send(.land, to: d)
        }

        let env = environment
        d.state = .onMission
        d.lastSector = v.nom
        neural.observe(sector: v.nom, environment: env.rawValue,
                       battery: d.battery)
        log("🧠 \(d.name) : exploration secteur \(v.nom) [\(env.rawValue)] — "
            + "LEDs coupées (économie).")
        send(.setLeds(intensity: 0), to: d)

        try? await Task.sleep(for: .seconds(2))          // stabilisation
        guard actif(), !poserSiBatterieCritique() else { return atterrir() }

        // Extérieur : phase de MONTÉE vers un plafond plus haut. Le lien BLE
        // reste ~20 m — l'IA garde le drone dans la bulle radio du téléphone.
        if env.climbGaz > 0 {
            log(String(format: "⬆︎ %@ : montée à ~%.0f m (%@).",
                       d.name, env.hoverAltitude, env.rawValue))
            send(.pcmd(roll: 0, pitch: 0, yaw: 0, gaz: env.climbGaz), to: d)
            try? await Task.sleep(for: .seconds(env.climbSeconds))
            stop()
            try? await Task.sleep(for: .seconds(0.6))
            guard actif(), !poserSiBatterieCritique() else { return atterrir() }
        }

        send(.takePicture, to: d)
        log("📷 \(d.name) : photo au point de départ.")
        try? await Task.sleep(for: .seconds(1))
        guard actif(), !poserSiBatterieCritique() else { return atterrir() }

        log("→ \(d.name) avance vers le \(v.nom)…")
        send(.pcmd(roll: v.roll, pitch: v.pitch, yaw: 0, gaz: 0), to: d)
        try? await Task.sleep(for: .seconds(env.advanceSeconds))
        stop()
        try? await Task.sleep(for: .seconds(1))
        guard actif(), !poserSiBatterieCritique() else { return atterrir() }

        send(.takePicture, to: d)
        log("📷 \(d.name) : photo secteur \(v.nom).")
        try? await Task.sleep(for: .seconds(1))
        guard actif() else { return atterrir() }

        // 🧠 DÉCISION SUR IMAGE (drones simulés : analyse immédiate — pour
        // les drones réels, le FTP Bluetooth interdit le transfert en vol,
        // l'analyse guide donc la mission SUIVANTE, voir fin de mission).
        if d.isSimulated, d.photoReturnEnabled {
            d.lastPhoto = Simulation.placeholderPhoto(drone: d.name,
                                                      secteur: v.nom)
            d.lastPhotoName = "sim_\(v.nom).jpg"
            d.lastPhotoDate = Date()
            if let jpeg = d.lastPhoto {
                persistPhoto(jpeg, for: d, name: d.lastPhotoName)
            }
            analyzePhoto(for: d, secteur: v.nom)
            if d.groundVerdict == "dégagé", !poserSiBatterieCritique() {
                log("🧠 \(d.name) : sol dégagé → j'explore 1 m plus loin.")
                send(.pcmd(roll: v.roll, pitch: v.pitch, yaw: 0, gaz: 0), to: d)
                try? await Task.sleep(for: .seconds(0.8))
                stop()
                try? await Task.sleep(for: .seconds(0.6))
            } else if d.groundVerdict == "encombré" {
                log("🧠 \(d.name) : sol encombré → retour anticipé, prudence.")
            }
            guard actif() else { return atterrir() }
        }

        log("↩︎ \(d.name) : retour base…")
        send(.pcmd(roll: -v.roll, pitch: -v.pitch, yaw: 0, gaz: 0), to: d)
        try? await Task.sleep(for: .seconds(env.advanceSeconds))
        stop()
        try? await Task.sleep(for: .seconds(1))

        atterrir()
        learn("✅ \(d.name) : mission secteur \(v.nom) terminée [\(env.rawValue)] "
            + "— batterie \(d.battery.map { "\($0) %" } ?? "?").")
        // 🔬 Apprentissage NEURONAL : renforce le réseau selon le résultat.
        let bat = d.battery ?? 50
        let encombre = (d.groundVerdict == "encombré")
        let valeur = min(1, max(0, 0.5 + Double(bat - 50) / 120.0
                                    + (encombre ? -0.25 : 0.25)))
        neural.reinforce(
            features: neuralFeatures(sector: v.nom, env: env.rawValue,
                                     battery: bat),
            explorer: valeur, risque: encombre ? 1 : 0)
        learn("🔬 Neurones : vol \(v.nom) intégré (valeur "
              + "\(String(format: "%.2f", valeur)) · \(neural.trainings) "
              + "apprentissages).")
        try? await Task.sleep(for: .seconds(3))
        if d.state == .landing { d.state = .grounded }
        // Retour image : rapatrie la dernière photo maintenant que le drone
        // est posé (le FTP Bluetooth sature la liaison — jamais en vol).
        // Respecte le réglage PAR DRONE (📷 sur la carte).
        if !d.photoReturnEnabled {
            log("📷 \(d.name) : retour image désactivé pour ce drone — "
                + "photos conservées à bord.")
        } else if d.isSimulated {
            // (photo déjà rapatriée et analysée en vol, cas simulé)
        } else {
            log("📥 \(d.name) : rapatriement de la dernière photo "
                + "(20-60 s en Bluetooth)…")
            send(.fetchPhoto(count: 1), to: d)
        }
        // 🧠 Apprentissage continu : débrief par l'API Claude (optionnel).
        // Sans clé, cette étape est simplement sautée.
        if brain.enabled {
            let ctx = "Drone \(d.name), environnement \(env.rawValue), secteur "
                + "\(v.nom), batterie finale "
                + "\(d.battery.map { "\($0) %" } ?? "?"), sol jugé "
                + "\(d.groundVerdict ?? "non analysé")."
            Task {
                if let txt = await self.brain.debrief(context: ctx) {
                    self.learn("🧠 Débrief Claude (\(d.name)) — \(txt)")
                }
            }
        }
        // Groupe revenu au complet ? → état « prêt »
        if let g = group(id: d.groupID),
           members(of: g).allSatisfy({ $0.state == .grounded
                                       || !$0.inGroupLogic }) {
            g.missionState = .idle
            log("🏁 \(g.name) : tous les drones posés — groupe prêt.")
        }
    }

    func landGroup(_ g: DroneGroup) {
        g.missionState = .landing
        for d in members(of: g) where d.state != .grounded && d.inGroupLogic {
            missions[d.id]?.cancel()
            d.state = .landing
            send(.land, to: d)
        }
        log("🛬 \(g.name) : atterrissage général.")
        Task {
            try? await Task.sleep(for: .seconds(4))
            for d in members(of: g) where d.state == .landing {
                d.state = .grounded
            }
            g.missionState = .idle
        }
    }

    /// URGENCE FLOTTE : coupe tout, tous groupes, tous modes.
    func emergencyAll() {
        log("⛔ URGENCE GÉNÉRALE — drones + Master S1.")
        for t in missions.values { t.cancel() }
        missions.removeAll()
        for d in drones where d.state != .grounded {
            d.state = .emergency
            send(.emergency, to: d)
        }
        for g in groups { g.missionState = .idle }
        // Arrêt immédiat du robot terrestre
        masterS1.emergencyStop()
    }

    /// Attend la confirmation de décollage (télémétrie « en vol » ou
    /// altitude > 0,5 m), avec délai maximal.
    private func waitAirborne(_ d: Drone, timeout: TimeInterval) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if d.altitude > 0.5 || d.state == .airborne { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    // MARK: - Entrées manette (mode Manuel) ----------------------------------------

    func manualInput(roll: Int, pitch: Int, yaw: Int, gaz: Int) {
        let active = roll != 0 || pitch != 0 || yaw != 0 || gaz != 0
        guard let d = manualTarget, d.mode == .manual else {
            if active { noTargetHint() }
            return
        }
        lastManualInput = "R\(roll) P\(pitch) L\(yaw) G\(gaz)"
        // Sticks actifs mais drone AU SOL : les consignes de vol n'ont aucun
        // effet tant qu'il n'a pas décollé — on le dit clairement.
        if active, d.state == .grounded,
           Date().timeIntervalSince(lastGroundedHint) > 5 {
            lastGroundedHint = Date()
            log("🎮 \(d.name) est AU SOL — appuie sur ✕ pour décoller, les "
                + "sticks n'agissent qu'en vol.")
        }
        // Pas de déluge de trames nulles : 1 « keepalive »/s quand les sticks
        // sont au repos, 10 Hz dès qu'ils bougent.
        if !active {
            guard Date().timeIntervalSince(lastZeroSent) >= 1 else { return }
            lastZeroSent = Date()
        }
        send(.pcmd(roll: roll, pitch: pitch, yaw: yaw, gaz: gaz), to: d)
    }

    /// L1 / R1 : LED du drone ciblé — le test TANGIBLE de toute la chaîne
    /// manette → Mac → WiFi → iPhone → Bluetooth → drone, sans faire voler.
    func manualLeds(intensity: Int) {
        guard let d = manualTarget, d.mode == .manual else {
            noTargetHint()
            return
        }
        send(.setLeds(intensity: intensity), to: d)
        log("🎮 \(d.name) : LEDs \(intensity) % (manette).")
    }

    func manualButton(takeoffLand: Bool) {
        guard let d = manualTarget, d.mode == .manual else {
            noTargetHint()
            return
        }
        if d.state == .grounded {
            d.state = .takingOff
            send(.takeOff, to: d)
        } else {
            d.state = .landing
            send(.land, to: d)
        }
    }

    /// ◄ ► sur la manette : fait tourner la cible parmi les drones en Manuel.
    func cycleManualTarget(_ direction: Int) {
        let manuels = drones.filter { $0.mode == .manual }
        guard !manuels.isEmpty else {
            log("🎮 ◄ ► : aucun drone en mode Manuel — clique d'abord 🎮 sur "
                + "la carte du ou des drones à piloter.")
            return
        }
        guard let cible = manualTarget,
              let idx = manuels.firstIndex(where: { $0 === cible }) else {
            manualTarget = manuels[0]
            log("🎮 La manette vise \(manuels[0].name).")
            return
        }
        let suivant = (idx + direction + manuels.count) % manuels.count
        manualTarget = manuels[suivant]
        log("🎮 ◄ ► La manette vise maintenant \(manuels[suivant].name) "
            + "(\(suivant + 1)/\(manuels.count) en Manuel).")
    }

    @ObservationIgnored private var lastGroundedHint = Date.distantPast

    /// La manette bouge mais aucun drone n'est en Manuel : on l'explique
    /// (une fois toutes les 5 s, pas un spam).
    private func noTargetHint() {
        guard Date().timeIntervalSince(lastNoTargetHint) > 5 else { return }
        lastNoTargetHint = Date()
        log("🎮 Manette active — passe d'abord un drone en MANUEL (segment 🎮 "
            + "de sa carte) : il deviendra la cible de la manette.")
    }

    // MARK: - Contrôle VOCAL --------------------------------------------------------

    /// Transforme une phrase reconnue en UNE commande. Renvoie true si un
    /// mot-clé a été reconnu. Cible = le drone en Manuel (comme la manette),
    /// sinon l'unique drone tenu. Les commandes de VOL passent par le même
    /// chemin que la manette (donc soumises au « Pilotage autorisé » du
    /// téléphone). L'atterrissage et l'urgence sont toujours permis.
    @discardableResult
    /// Situation synthétique pour Claude (contexte d'ordre).
    func situationBrief() -> String {
        let dLines = drones.map { d in
            "\(d.name) id=\(d.id) état=\(d.state.rawValue) mode=\(d.mode.rawValue) "
                + "bat=\(d.battery.map(String.init) ?? "?")% groupe=\(d.groupID ?? "—")"
        }.joined(separator: "\n")
        let s1 = masterS1.unit
        let g = gardien
        return """
        Drones:
        \(dLines.isEmpty ? "(aucun)" : dLines)
        Cible manuelle: \(manualTarget?.name ?? "aucune")
        Environnement: \(environment.rawValue)
        Master S1: \(s1.state.rawValue) bat=\(s1.battery.map(String.init) ?? "?")% ip=\(s1.ip)
        Gardien: \(g.statusLine) url=\(g.remoteURL)
        """
    }

    /// Exécute un plan d'ordres Claude. Filtre de sécurité anti-code/désarmement.
    func executeAIOrders(_ orders: [[String: Any]], reply: String) {
        if !reply.isEmpty {
            log("🧠 LIA : \(reply)")
            brain.lastAssessment = reply
        }
        for raw in orders {
            let domain = ((raw["domain"] as? String) ?? "").lowercased()
            let action = ((raw["action"] as? String) ?? "").lowercased()
            let params = (raw["params"] as? [String: Any]) ?? [:]

            // ── FILTRE ABSOLU : jamais de code / désarmement via l'IA ──
            if Self.isForbiddenAIAction(domain: domain, action: action, params: params) {
                log("🛡 ORDRE IA REFUSÉ (réservé humain) : \(domain).\(action)")
                gardien.refuseAIDisarm()
                continue
            }

            switch domain {
            case "fleet":
                applyFleetAI(action: action, params: params)
            case "drone":
                applyDroneAI(action: action, params: params)
            case "s1", "master", "ground", "terrestre":
                applyS1AI(action: action, params: params)
            case "gardien", "security", "surveillance":
                applyGardienAI(action: action, params: params)
            default:
                log("🧠 Domaine IA inconnu : \(domain)")
            }
        }
    }

    /// Mots/actions interdits à l'IA (codes et désarmement uniquement humains).
    private static func isForbiddenAIAction(domain: String, action: String,
                                            params: [String: Any]) -> Bool {
        let blob = (
            domain + " " + action + " " + params.description
        ).folding(options: .diacriticInsensitive, locale: .current).lowercased()
        let banned = [
            "desarmer", "desarm", "disarm", "code_sha", "set_code", "definir_code",
            "changer_code", "password", "motdepasse", "pin ", " pin", "code:",
            "code=", "nouveau_code", "ancien_code", "unlock_code", "desactivation",
        ]
        if banned.contains(where: { blob.contains($0) }) { return true }
        // Action explicite
        if action.contains("desarm") || action.contains("code") { return true }
        return false
    }

    private func applyFleetAI(action: String, params: [String: Any]) {
        switch action {
        case "emergency_all", "urgence", "stop_all":
            emergencyAll()
        case "launch_group", "lancer_groupe":
            let gid = (params["group"] as? String) ?? "A"
            if let g = groups.first(where: { $0.id == gid }) {
                launchGroup(g)
            }
        case "land_group", "atterrir_groupe":
            let gid = (params["group"] as? String) ?? "A"
            if let g = groups.first(where: { $0.id == gid }) {
                landGroup(g)
            }
        default:
            log("🧠 fleet.\(action) non géré")
        }
    }

    private func applyDroneAI(action: String, params: [String: Any]) {
        let d = resolveDrone(params) ?? manualTarget ?? drones.first
        guard let d else {
            log("🧠 Aucun drone pour l'ordre \(action)")
            return
        }
        switch action {
        case "take_off", "decolle", "decollage":
            if d.state == .grounded { d.state = .takingOff; send(.takeOff, to: d) }
        case "land", "atterri", "atterrissage":
            d.state = .landing; send(.land, to: d)
        case "emergency", "urgence":
            d.state = .emergency; send(.emergency, to: d)
        case "photo", "take_picture":
            send(.takePicture, to: d)
        case "leds", "set_leds":
            let i = params["intensity"] as? Int ?? 100
            send(.setLeds(intensity: i), to: d)
        case "pcmd", "move", "vol":
            let r = params["roll"] as? Int ?? 0
            let p = params["pitch"] as? Int ?? 0
            let y = params["yaw"] as? Int ?? 0
            let g = params["gaz"] as? Int ?? 0
            voiceNudge(d, roll: r, pitch: p, yaw: y, gaz: g, label: "IA \(action)")
        case "set_mode", "mode":
            if let m = params["mode"] as? String {
                switch m.lowercased() {
                case "ia", "auto": d.mode = .ia; d.inGroupLogic = true
                case "semi": d.mode = .semi; d.inGroupLogic = true
                case "manuel", "manual": d.mode = .manual; d.inGroupLogic = false; manualTarget = d
                default: break
                }
                log("🧠 \(d.name) → mode \(d.mode.rawValue)")
            }
        default:
            log("🧠 drone.\(action) non géré")
        }
    }

    private func resolveDrone(_ params: [String: Any]) -> Drone? {
        if let id = params["drone"] as? String {
            return drones.first {
                $0.id == id || $0.name.localizedCaseInsensitiveContains(id)
                    || ($0.bleName?.localizedCaseInsensitiveContains(id) ?? false)
            }
        }
        return nil
    }

    private func applyS1AI(action: String, params: [String: Any]) {
        switch action {
        case "connect", "connecter":
            masterS1.connect(ip: params["ip"] as? String)
        case "disconnect", "deconnecter":
            masterS1.disconnect()
        case "stop", "stop_chassis":
            masterS1.stopChassis()
        case "patrol", "patrouille":
            masterS1.patrolDemo()
        case "fire", "tir", "blaster":
            masterS1.fire()
        case "gimbal_center", "recenter", "gimbal_recenter":
            masterS1.gimbalRecenter()
        case "chassis", "move":
            let x = (params["x"] as? Double) ?? (params["x"] as? Int).map(Double.init) ?? 0
            let y = (params["y"] as? Double) ?? (params["y"] as? Int).map(Double.init) ?? 0
            let z = (params["z"] as? Double) ?? (params["z"] as? Int).map(Double.init) ?? 0
            masterS1.chassis(x: x, y: y, z: z)
        case "mode", "set_mode":
            if let m = params["mode"] as? String,
               let mode = GroundRobotMode(rawValue: m) {
                masterS1.setMode(mode)
            }
        case "led", "leds":
            let r = params["r"] as? Int ?? 0
            let g = params["g"] as? Int ?? 255
            let b = params["b"] as? Int ?? 80
            masterS1.setLED(r: r, g: g, b: b)
        default:
            log("🧠 s1.\(action) non géré")
        }
    }

    private func applyGardienAI(action: String, params: [String: Any]) {
        // Double filet anti-désarmement
        if action.contains("desarm") || action.contains("code") {
            gardien.refuseAIDisarm()
            return
        }
        switch action {
        case "wake_camera", "camera", "activer_camera", "scan":
            gardien.wakeCamera(openApp: true)
        case "open_app", "ouvrir_app":
            gardien.openGardienApp()
        case "arm", "armer", "surveillance":
            gardien.armSurveillance()
        case "status", "statut":
            gardien.refresh()
            log("🛡 \(gardien.statusLine)")
        case "copy_url":
            gardien.copyRemoteURL()
        default:
            log("🧠 gardien.\(action) non géré (désarmement interdit à l'IA)")
        }
    }

    /// Point d'entrée unique : Claude d'abord, sinon mots-clés locaux.
    @discardableResult
    func handleCommand(_ phrase: String) -> Bool {
        let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return false }

        // Refus immédiat si l'humain dicte un code à l'IA pour désarmer
        let low = p.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        if low.contains("desarme") || low.contains("desarmer")
            || (low.contains("code") && (low.contains("desarm") || low.contains("desactive"))) {
            log("🛡 « \(phrase) » — désarmement / code : saisie manuelle uniquement "
                + "(app Gardien ou téléphone), pas via LIA.")
            return true
        }

        if brain.enabled {
            Task { @MainActor in
                self.log("🧠 LIA interprète : « \(phrase) »…")
                if let plan = await self.brain.interpretOrder(
                    phrase, situation: self.situationBrief()
                ) {
                    self.executeAIOrders(plan.orders, reply: plan.reply)
                } else {
                    self.log("🧠 LIA indisponible — mots-clés locaux.")
                    _ = self.handleVoiceLocal(phrase)
                }
            }
            return true
        }
        return handleVoiceLocal(phrase)
    }

    func handleVoice(_ phrase: String) -> Bool {
        handleCommand(phrase)
    }

    /// Mots-clés locaux (secours sans Claude).
    func handleVoiceLocal(_ phrase: String) -> Bool {
        let p = phrase.folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()

        // Urgence : priorité absolue, sans cible.
        if p.contains("urgence") || p.contains("arrete tout")
            || p.contains("stop tout") || p.contains("coupe tout") {
            log("🎙️ « \(phrase) » → URGENCE GÉNÉRALE.")
            emergencyAll()
            return true
        }

        // Master S1 (local)
        if p.contains("master") || p.contains("s1") || p.contains("robot") {
            if p.contains("connect") || p.contains("branche") {
                masterS1.connect(); return true
            }
            if p.contains("stop") || p.contains("arrete") {
                masterS1.stopChassis(); return true
            }
            if p.contains("patrouill") {
                masterS1.patrolDemo(); return true
            }
            if p.contains("fire") || p.contains("tire") {
                masterS1.fire(); return true
            }
        }
        // Gardien (local) — jamais désarmer
        if p.contains("gardien") || p.contains("camera") || p.contains("surveillance") {
            if p.contains("desarm") || p.contains("code") {
                log("🛡 Désarmement : code manuel uniquement.")
                return true
            }
            if p.contains("arme") { gardien.armSurveillance(); return true }
            gardien.wakeCamera(openApp: true); return true
        }

        let cible = manualTarget ?? (drones.count == 1 ? drones.first : nil)
        guard let d = cible else {
            log("🎙️ « \(phrase) » ignoré : aucun drone ciblé. Passe un drone "
                + "en MANUEL (🎮) ou n'en garde qu'un pour le piloter à la voix.")
            return false
        }

        // Actions discrètes
        if p.contains("decolle") || p.contains("decollage") {
            log("🎙️ « \(phrase) » → décollage de \(d.name).")
            if d.state == .grounded { d.state = .takingOff; send(.takeOff, to: d) }
            return true
        }
        if p.contains("atterri") || p.contains("pose")
            || p.contains("atterrissage") {
            log("🎙️ « \(phrase) » → atterrissage de \(d.name).")
            d.state = .landing; send(.land, to: d)
            return true
        }
        if p.contains("photo") {
            log("🎙️ « \(phrase) » → photo de \(d.name).")
            send(.takePicture, to: d); return true
        }
        if p.contains("lumiere") || p.contains("allume") || p.contains("phare") {
            log("🎙️ « \(phrase) » → LEDs allumées (\(d.name)).")
            send(.setLeds(intensity: 100), to: d); return true
        }
        if p.contains("eteins") || p.contains("eteindre") || p.contains("noir") {
            log("🎙️ « \(phrase) » → LEDs éteintes (\(d.name)).")
            send(.setLeds(intensity: 0), to: d); return true
        }
        if p.contains("stationnaire") || p.contains("immobile")
            || p.contains("stop") {
            log("🎙️ « \(phrase) » → stationnaire (\(d.name)).")
            send(.pcmd(roll: 0, pitch: 0, yaw: 0, gaz: 0), to: d); return true
        }

        // Pilotage (impulsion ~1 s) — rotations avant « gauche/droite » simples
        if p.contains("tourne"), p.contains("gauche") {
            return voiceNudge(d, yaw: -50, label: phrase) }
        if p.contains("tourne"), p.contains("droite") {
            return voiceNudge(d, yaw: 50, label: phrase) }
        if p.contains("avance") || p.contains("devant") || p.contains("tout droit") {
            return voiceNudge(d, pitch: 30, label: phrase) }
        if p.contains("recule") || p.contains("arriere") {
            return voiceNudge(d, pitch: -30, label: phrase) }
        if p.contains("gauche") { return voiceNudge(d, roll: -30, label: phrase) }
        if p.contains("droite") { return voiceNudge(d, roll: 30, label: phrase) }
        if p.contains("monte") || p.contains("plus haut") {
            return voiceNudge(d, gaz: 40, label: phrase) }
        if p.contains("descend") || p.contains("plus bas") || p.contains("baisse") {
            return voiceNudge(d, gaz: -40, label: phrase) }

        return false      // aucun mot-clé reconnu
    }

    /// Impulsion de pilotage ~1 s puis stationnaire (comme un coup de stick).
    @discardableResult
    private func voiceNudge(_ d: Drone, roll: Int = 0, pitch: Int = 0,
                            yaw: Int = 0, gaz: Int = 0, label: String) -> Bool {
        guard !d.batteryEmergency else {
            log("🎙️ \(d.name) : batterie < 25 % — commande de vol refusée.")
            return true
        }
        guard d.state != .grounded else {
            log("🎙️ « \(label) » : \(d.name) est au sol — dis d'abord « décolle ».")
            return true
        }
        log("🎙️ « \(label) » → \(d.name) bouge (1 s).")
        send(.pcmd(roll: roll, pitch: pitch, yaw: yaw, gaz: gaz), to: d)
        Task {
            try? await Task.sleep(for: .seconds(1))
            send(.pcmd(roll: 0, pitch: 0, yaw: 0, gaz: 0), to: d)
        }
        return true
    }

    // MARK: - Retour image manuel ---------------------------------------------------

    /// Récupération MANUELLE des photos (FTP Bluetooth) — le drone doit être
    /// POSÉ (le FTP sature la liaison BLE, impossible en vol).
    func fetchPhotosNow(_ d: Drone) {
        guard !d.isSimulated else {
            log("📥 \(d.name) : drone simulé — pas de vrai transfert FTP.")
            return
        }
        guard d.phone != nil else {
            log("📥 \(d.name) : aucun téléphone ne le tient — impossible de "
                + "récupérer les photos.")
            return
        }
        guard d.state == .grounded else {
            log("📥 \(d.name) : POSE-LE d'abord — le FTP Bluetooth ne "
                + "fonctionne qu'au sol.")
            return
        }
        log("📥 \(d.name) : récupération manuelle des photos (FTP Bluetooth, "
            + "20-60 s). Si rien ne revient : Réglages → Logs sur le téléphone.")
        send(.fetchPhoto(count: 3), to: d)
    }

    // MARK: - Divers -----------------------------------------------------------------

    func send(_ cmd: DroneCommand, to d: Drone) {
        // Le téléphone identifie ses drones par leur NOM BLE (Blaze_… / RS_…)
        var msg: [String: Any] = ["type": "command",
                                  "drone": d.bleName ?? d.id]
        cmd.json.forEach { msg[$0] = $1 }
        server.send(to: d, msg)
        if d.isSimulated { Simulation.apply(cmd, to: d) }
    }

    func log(_ msg: String) {
        journal.append(msg)
        if journal.count > 200 { journal.removeFirst(100) }
    }

    // MARK: - Photos revenues → dossier sur le Bureau ----------------------------

    /// Dossier « Airborne Commander - Photos » sur le Bureau (créé au besoin).
    @ObservationIgnored private lazy var photoDir: URL? = {
        let fm = FileManager.default
        guard let desktop = fm.urls(for: .desktopDirectory,
                                    in: .userDomainMask).first else { return nil }
        let dir = desktop.appendingPathComponent("Airborne Commander - Photos",
                                                 isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    @ObservationIgnored private static let photoStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f
    }()

    /// Écrit sur le Bureau une photo revenue d'un drone. Nom :
    /// « Drone 01_20260712-224500_secteur.jpg ».
    @discardableResult
    func persistPhoto(_ jpeg: Data, for drone: Drone, name: String?) -> URL? {
        guard let dir = photoDir else { return nil }
        let base = name.map { ($0 as NSString).deletingPathExtension } ?? "photo"
        let safeDrone = drone.name.replacingOccurrences(of: " ", with: "_")
        let file = dir.appendingPathComponent(
            "\(safeDrone)_\(Self.photoStamp.string(from: Date()))_\(base).jpg")
        do {
            try jpeg.write(to: file)
            log("💾 Photo de \(drone.name) enregistrée sur le Bureau "
                + "(Airborne Commander - Photos/\(file.lastPathComponent)).")
            return file
        } catch {
            log("⚠️ Écriture photo échouée : \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Mémoire PERSISTANTE (apprentissage continu) ------------------------
    //
    // Survit aux redémarrages : mémoire des secteurs (encombré/dégagé), journal
    // de vol daté, et config de la flotte (groupe + mode par nom BLE). Stockée
    // dans ~/Library/Application Support/AirborneCommander/.

    @ObservationIgnored private lazy var memoryDir: URL? = {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("AirborneCommander",
                                              isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var sectorFile: URL? {
        memoryDir?.appendingPathComponent("memoire_secteurs.json") }
    private var journalFile: URL? {
        memoryDir?.appendingPathComponent("journal_de_vol.md") }
    private var configFile: URL? {
        memoryDir?.appendingPathComponent("config_flotte.json") }

    struct DroneConfig: Codable { var group: String?; var mode: String }
    @ObservationIgnored private var savedConfig: [String: DroneConfig] = [:]

    /// Chargé au démarrage : restaure secteurs, journal et config.
    func loadMemory() {
        if let f = sectorFile, let d = try? Data(contentsOf: f),
           let m = try? JSONDecoder().decode([String: String].self, from: d) {
            sectorKnowledge = m
            if !m.isEmpty {
                log("🧠 Mémoire rechargée : \(m.count) secteur(s) connu(s) "
                    + "(\(m.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))).")
            }
        }
        if let f = configFile, let d = try? Data(contentsOf: f),
           let c = try? JSONDecoder().decode([String: DroneConfig].self,
                                             from: d) {
            savedConfig = c
        }
        if let f = journalFile,
           let text = try? String(contentsOf: f, encoding: .utf8) {
            let lignes = text.split(separator: "\n").suffix(30).map(String.init)
            if !lignes.isEmpty {
                log("📖 Journal de vol repris (\(lignes.count) derniers "
                    + "évènements) :")
                journal.append(contentsOf: lignes)
            }
        }
    }

    private func saveSectorKnowledge() {
        guard let f = sectorFile,
              let d = try? JSONEncoder().encode(sectorKnowledge) else { return }
        try? d.write(to: f, options: .atomic)
    }

    private func saveConfig() {
        guard let f = configFile,
              let d = try? JSONEncoder().encode(savedConfig) else { return }
        try? d.write(to: f, options: .atomic)
    }

    /// Mémorise groupe + mode d'un drone (par nom BLE).
    func rememberConfig(_ d: Drone) {
        guard let ble = d.bleName else { return }
        savedConfig[ble] = DroneConfig(group: d.groupID, mode: d.mode.rawValue)
        saveConfig()
    }

    /// Restaure groupe + mode mémorisés quand un drone (re)apparaît. NE relance
    /// PAS de mission — restaure juste l'affectation (le drone reste au sol).
    func restoreConfig(for d: Drone) {
        guard let ble = d.bleName, let c = savedConfig[ble] else { return }
        d.groupID = c.group
        if let m = DroneMode(rawValue: c.mode) { d.mode = m }
        log("↺ \(d.name) : configuration restaurée "
            + "(\(group(id: c.group)?.name ?? "sans groupe"), \(c.mode)).")
    }

    /// Journalise ET consigne DURABLEMENT un évènement d'apprentissage
    /// (missions, verdicts, débriefs) — pas le bruit de télémétrie.
    func learn(_ line: String) {
        log(line)
        guard let f = journalFile else { return }
        let stamp = FleetEngine.jStamp.string(from: Date())
        let entry = "- \(stamp) \(line)\n"
        if let h = try? FileHandle(forWritingTo: f) {
            h.seekToEndOfFile()
            h.write(entry.data(using: .utf8) ?? Data())
            try? h.close()
        } else {
            try? entry.write(to: f, atomically: true, encoding: .utf8)
        }
    }

    @ObservationIgnored private static let jStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f
    }()

    // MARK: - Escadrille de démonstration ----------------------------------------------

    func addDemoSquadron() {
        // Les deux manettes factices apparaissent aussi dans l'inventaire
        for nom in ["iPhone-11-Alpha", "iPhone-11-Bravo"]
        where !phones.contains(where: { $0.name == nom }) {
            let p = PhoneRelay(name: nom)
            p.version = "démo"
            p.ios = "simulation"
            phones.append(p)
        }
        let start = drones.count
        for i in 1...4 {
            let n = start + i
            let d = Drone(id: "drone-\(String(format: "%02d", n))",
                          name: "Drone \(String(format: "%02d", n))")
            d.bleName = "Blaze_SIM\(n)"
            d.phone = n <= 2 ? "iPhone-11-Alpha" : "iPhone-11-Bravo"
            d.battery = [92, 78, 64, 55][i - 1]
            d.signal = .fort
            d.isSimulated = true
            d.lastSeen = Date()
            d.groupID = i <= 3 ? "A" : "B"   // pré-assignés, modifiable via ⚙︎
            drones.append(d)
        }
        log("Escadrille de démo ajoutée (4 drones sur 2 iPhones simulés).")
        if simTimer == nil {
            simTimer = Timer.scheduledTimer(withTimeInterval: 1.5,
                                            repeats: true) { _ in
                Task { @MainActor in Simulation.tick(FleetEngine.shared) }
            }
        }
    }
}

// MARK: - Physique simplifiée des drones simulés (mode démo)
@MainActor
enum Simulation {

    /// Photo factice « caméra verticale » pour le retour image en démo.
    static func placeholderPhoto(drone: String, secteur: String) -> Data? {
        let taille = NSSize(width: 320, height: 240)
        let image = NSImage(size: taille)
        image.lockFocus()
        // Sol vu du dessus : dégradé + « dalles » aléatoires
        NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.14,
                                    blue: 0.12, alpha: 1),
                            NSColor(calibratedRed: 0.35, green: 0.30,
                                    blue: 0.24, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: taille), angle: 60)
        for _ in 0..<14 {
            NSColor(white: .random(in: 0.2...0.8), alpha: 0.35).setFill()
            NSRect(x: .random(in: 0...290), y: .random(in: 0...210),
                   width: .random(in: 12...60),
                   height: .random(in: 12...60)).fill()
        }
        let texte = "\(drone) — secteur \(secteur)\n"
            + Date().formatted(date: .omitted, time: .standard)
        (texte as NSString).draw(
            at: NSPoint(x: 10, y: 8),
            withAttributes: [.foregroundColor: NSColor.white,
                             .font: NSFont.monospacedSystemFont(
                                ofSize: 12, weight: .bold)])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg,
                                  properties: [.compressionFactor: 0.8])
    }
    static func apply(_ cmd: DroneCommand, to d: Drone) {
        switch cmd {
        case .takeOff:
            Task {   // montée progressive → le séquencement se VOIT
                try? await Task.sleep(for: .seconds(1.5))
                d.altitude = 1.1
            }
        case .land, .emergency:
            d.altitude = 0
            if case .emergency = cmd { d.state = .grounded }
        case .pcmd(_, _, _, let gaz) where gaz > 0:
            // Montée (extérieur) : l'altitude simulée grimpe visiblement.
            d.altitude = min(6, d.altitude + Double(gaz) / 25.0)
        default: break
        }
    }

    static func tick(_ engine: FleetEngine) {
        for d in engine.drones where d.isSimulated {
            if let b = d.battery, d.state != .grounded {
                d.battery = max(0, b - 1)
            }
            if d.state == .onMission {
                d.distance = min(12, d.distance + Double.random(in: 0.2...0.8))
                d.signal = d.distance > 10 ? .moyen : .fort
                // Le signal se dégrade en s'éloignant → déclenche le handover
                d.rssi = max(-95, (d.rssi ?? -55) - Int.random(in: 6...12))
            } else if d.state == .grounded {
                d.distance = 0
                d.altitude = 0
                d.rssi = -55
            }
            d.lastSeen = Date()
        }
    }
}

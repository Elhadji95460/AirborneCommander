import Foundation
import Observation

// MARK: - AIRBORNE COMMANDER V5 — Modèles
//
// Le Mac est le POSTE DE COMMANDEMENT : il ne touche jamais au Bluetooth.
// Chaque iPhone-relais tient 1 ou 2 drones Parrot en BLE et exécute les
// commandes reçues du Mac en WebSocket (voir CommandServer).

// MARK: Modes d'un drone
enum DroneMode: String, Codable, CaseIterable, Identifiable {
    case ia = "IA 100 %"        // totalement autonome (FleetEngine décide)
    case semi = "Semi-IA"       // trajectoire IA, corrections manuelles admises
    case manual = "Manuel"      // manette PS5 DualSense — sort de la logique
                                // de groupe tant que le mode est actif
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .ia: "brain.head.profile"
        case .semi: "slider.horizontal.below.square.filled.and.square"
        case .manual: "gamecontroller.fill"
        }
    }
}

// MARK: Environnement de vol (intérieur / extérieur)
//
// Pilote les PARAMÈTRES de mission de l'IA. Intérieur = comportement des
// versions précédentes (bas, lent, précis). Extérieur = plafond plus haut
// (phase de montée après décollage), trajets plus longs.
// ⚠️ Contrainte honnête : le lien BLE reste ~20 m même dehors — l'IA doit
// garder le drone DANS LA BULLE RADIO du téléphone qui le tient.
enum FlightEnvironment: String, Codable, CaseIterable, Identifiable {
    case interieur = "Intérieur"
    case exterieur = "Extérieur"
    var id: String { rawValue }

    var symbol: String {
        self == .interieur ? "house.fill" : "sun.max.fill"
    }

    /// Altitude visée en vol stationnaire (m).
    var hoverAltitude: Double { self == .interieur ? 1.1 : 3.0 }
    /// Gaz de la phase de montée (0 = pas de montée dédiée, intérieur).
    var climbGaz: Int { self == .interieur ? 0 : 45 }
    /// Durée de la phase de montée (s).
    var climbSeconds: Double { self == .interieur ? 0 : 1.2 }
    /// Durée d'une avancée dans un secteur (s) — plus long dehors.
    var advanceSeconds: Double { self == .interieur ? 1.5 : 3.0 }

    /// Rappel affiché à l'utilisateur.
    var hint: String {
        self == .interieur
            ? "Stabilité et précision : bas, lent, anti-collision."
            : "Altitude plus haute et trajets plus longs. Attention : le "
              + "Bluetooth porte ~20 m même dehors — reste dans la bulle radio."
    }
}

// MARK: États de vol
enum FlightState: String, Codable {
    case grounded = "au sol"
    case takingOff = "décollage…"
    case airborne = "en vol"
    case onMission = "en mission"
    case landing = "atterrissage…"
    case emergency = "URGENCE"
    case linkLost = "liaison perdue"
}

// MARK: Signal Bluetooth (rapporté par l'iPhone qui tient le drone)
enum BTSignal: String, Codable {
    case fort = "Fort", moyen = "Moyen", faible = "Faible", perdu = "Perdu"
}

// MARK: - Drone
@Observable
final class Drone: Identifiable {
    let id: String                  // identifiant stable ("drone-01")
    var name: String                // « Drone 01 » (nom BLE réel : Blaze_xxx)
    var bleName: String?
    var phone: String?              // iPhone-relais qui le tient
    var mode: DroneMode = .ia
    var groupID: String?            // UN SEUL groupe par drone (règle V5)
    var state: FlightState = .grounded
    var inGroupLogic = true         // false = override Manuel : hors groupe

    // Télémétrie temps réel (remontée par l'iPhone)
    var battery: Int?
    var altitude: Double = 0        // m (sonar)
    var distance: Double = 0        // m estimés (RSSI côté iPhone)
    var signal: BTSignal = .perdu
    var lastSeen: Date?

    // Retour image : dernière photo rapatriée du drone (caméra verticale,
    // via FTP Bluetooth par le téléphone — pas de vidéo possible en BLE)
    var lastPhoto: Data?
    var lastPhotoName: String?
    var lastPhotoDate: Date?
    var lastSector: String?         // secteur de la dernière mission
    var groundScore: Double?        // encombrement du sol (analyse IA)
    var groundVerdict: String?      // « dégagé » / « encombré »
    /// Retour image activable PAR DRONE (choix mémorisé par nom BLE —
    /// ex. désactivé pour RS_B103120 à la demande de l'utilisateur).
    var photoReturnEnabled = true

    // Handover automatique entre iPhones
    var rssi: Int?                          // dBm lissé (lu par l'iPhone)
    var handover: HandoverState = .none
    @ObservationIgnored var lowSignalStreak = 0

    var isSimulated = false

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// Urgence batterie (< 25 %) : mode Manuel refusé, atterrissage prioritaire
    var batteryEmergency: Bool { (battery ?? 100) < 25 }
}

// MARK: - Handover : états du transfert de relais entre iPhones
enum HandoverState: Equatable {
    case none
    case releasing                  // l'ancien iPhone libère le drone
    case scouting                   // les candidats sondent le signal
    case transferring(String)       // le gagnant prend le relais

    var label: String? {
        switch self {
        case .none: nil
        case .releasing: "↔︎ libération…"
        case .scouting: "↔︎ sondage du signal…"
        case .transferring(let p): "↔︎ relais vers \(p)…"
        }
    }
}

// MARK: - Manette (iPhone-relais) connue du poste de commandement
@Observable
final class PhoneRelay: Identifiable {
    let name: String
    var connected = true
    var lastSeen = Date()
    var version: String?        // version de l'app Drone Flotte embarquée
    var ios: String?            // version iOS du téléphone
    var id: String { name }
    init(name: String) { self.name = name }
}

// MARK: - Groupe
@Observable
final class DroneGroup: Identifiable {
    let id: String                          // "A", "B", "C", "D"…
    var name: String { "Groupe \(id)" }
    var missionState: GroupMissionState = .idle
    var takeoffIndex = 0                    // progression du décollage séquentiel
    var takeoffCount = 0                    // nombre de drones à décoller

    init(id: String) { self.id = id }
}

enum GroupMissionState: String {
    case idle = "prêt"
    case launching = "décollage séquentiel"
    case mission = "mission en cours"
    case landing = "atterrissage"
}

// MARK: - Protocole WebSocket (Mac ⇄ iPhones), vocabulaire JSON
//
// iPhone → Mac : {"type":"hello","phone":"iPhone-1","drones":["Blaze_1","Blaze_2"]}
//                {"type":"telemetry","drone":"drone-01","battery":72,
//                 "altitude":1.2,"distance":6.5,"signal":"Fort","state":"en vol"}
//                {"type":"event","drone":"drone-01","msg":"…"}
// Mac → iPhone : {"type":"welcome","id":"iPhone-1"}
//                {"type":"command","drone":"drone-01","action":"take_off"}
//                 actions : take_off · land · emergency · start_mission ·
//                           pcmd (roll/pitch/yaw/gaz -100..100) ·
//                           set_leds · take_picture · set_mode
//                {"type":"decision","msg":"…"}   (affichage sur le téléphone)
enum DroneCommand {
    case takeOff, land, emergency, startMission
    case pcmd(roll: Int, pitch: Int, yaw: Int, gaz: Int)
    case setLeds(intensity: Int)
    case takePicture
    case fetchPhoto(count: Int)     // rapatrier les dernières photos (FTP BLE)

    var json: [String: Any] {
        switch self {
        case .takeOff: ["action": "take_off"]
        case .land: ["action": "land"]
        case .emergency: ["action": "emergency"]
        case .startMission: ["action": "start_mission"]
        case .pcmd(let r, let p, let y, let g):
            ["action": "pcmd", "roll": r, "pitch": p, "yaw": y, "gaz": g]
        case .setLeds(let i): ["action": "set_leds", "mode": 0, "intensity": i]
        case .takePicture: ["action": "take_picture"]
        case .fetchPhoto(let n): ["action": "fetch_photo", "count": n]
        }
    }
}

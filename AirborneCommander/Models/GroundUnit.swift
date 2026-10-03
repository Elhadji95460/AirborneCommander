import Foundation
import Observation

// MARK: - Unité TERRESTRE (RoboMaster S1)
//
// Complément de la flotte aérienne (drones Parrot) : robot de sol DJI
// RoboMaster S1 — « Master S1 ».

enum GroundUnitState: String, Codable {
    case offline = "hors ligne"
    case connecting = "connexion…"
    case ready = "prêt"
    case moving = "en mouvement"
    case emergency = "URGENCE"
    case error = "erreur"
}

enum GroundRobotMode: String, CaseIterable, Identifiable {
    case free = "free"
    case chassisLead = "chassis_lead"
    case gimbalLead = "gimbal_lead"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .free: "Libre"
        case .chassisLead: "Châssis mène"
        case .gimbalLead: "Gimbal mène"
        }
    }
}

@Observable
final class GroundUnit: Identifiable {
    let id: String
    var name: String
    var model: String               // "RoboMaster S1"
    var ip: String
    var state: GroundUnitState = .offline
    var battery: Int?
    var pitch: Double = 0
    var yaw: Double = 0
    var robotMode: GroundRobotMode = .free
    var lastHit: String?
    var lastSeen: Date?
    var statusDetail: String = "Non connecté"
    var isSimulated = false

    init(
        id: String = "master-s1",
        name: String = "Master S1",
        model: String = "RoboMaster S1",
        ip: String = "192.168.2.1"
    ) {
        self.id = id
        self.name = name
        self.model = model
        self.ip = ip
    }

    var connected: Bool {
        state != .offline && state != .error && state != .connecting
    }
}

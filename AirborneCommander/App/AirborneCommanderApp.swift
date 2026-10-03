import SwiftUI

// MARK: - AIRBORNE COMMANDER V5 — poste de commandement Mac
//
// Le Mac est le serveur central et l'IA de la flotte :
//   FleetEngine      — groupes, décollage séquentiel, modes IA/Semi-IA/Manuel
//   CommandServer    — WebSocket ws://IP:5570 vers les iPhones-relais
//   DualSenseManager — manette PS5 pour le mode Manuel
//   GardienBridge    — surveillance / tunnel / caméra (serveur Gardien :8765)
//   MasterS1Bridge   — robot terrestre DJI RoboMaster S1 (SDK texte :40923)
//
// Les iPhones tiennent les drones en Bluetooth (1 iPhone = 1-2 drones) et
// exécutent les commandes : le Mac ne touche jamais au BLE.
// Gardien reste un processus Python séparé ; Commander le pilote via HTTP.
// Master S1 : Wi‑Fi Direct du robot (192.168.2.1), pilotage natif Swift.
@main
struct AirborneCommanderApp: App {
    var body: some Scene {
        WindowGroup {
            DashboardView()
                .frame(minWidth: 1080, minHeight: 680)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

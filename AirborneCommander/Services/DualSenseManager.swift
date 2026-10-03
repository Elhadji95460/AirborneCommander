import Foundation
import GameController
import Observation

// MARK: - DualSenseManager : la manette PS5 du commandant
//
// N'importe quel drone peut passer en MANUEL à tout moment : il devient la
// cible de la manette (engine.manualTarget) et sort de la logique de groupe.
//
// Mapping DualSense → ARSDK PCMD (roll/pitch/yaw/gaz, -100…100) :
//   Stick gauche  : gaz (vertical) + yaw (horizontal)
//   Stick droit   : pitch (vertical) + roll (horizontal)
//   Croix (✕)     : décollage / atterrissage du drone ciblé
//   Rond (○)      : URGENCE générale (coupe toute la flotte)
//   Carré (□)     : photo
//   L1 / R1       : LEDs éteintes / LEDs 100 % — test visible de la chaîne
//                   complète sans faire voler le drone
//
// Le flux PCMD est envoyé à ~10 Hz vers l'iPhone qui tient le drone — le
// minidrone attend ce rythme ; l'iPhone le relaie en BLE.
@Observable
final class DualSenseManager {

    var connected = false
    var controllerName: String?

    @ObservationIgnored private weak var engine: FleetEngine?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var roll = 0
    @ObservationIgnored private var pitch = 0
    @ObservationIgnored private var yaw = 0
    @ObservationIgnored private var gaz = 0

    init(engine: FleetEngine) {
        self.engine = engine
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.attach(note.object as? GCController)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.connected = false
                self?.controllerName = nil
                self?.engine?.log("🎮 Manette déconnectée.")
            }
        }
        GCController.startWirelessControllerDiscovery()
        if let c = GCController.controllers().first {
            Task { @MainActor in self.attach(c) }
        }
    }

    @MainActor
    private func attach(_ controller: GCController?) {
        guard let controller, let pad = controller.extendedGamepad else { return }
        connected = true
        controllerName = controller.vendorName ?? "Manette"
        engine?.log("🎮 \(controllerName!) connectée — prête pour le mode Manuel.")

        // Chaque appui est journalisé : le journal désigne ainsi précisément
        // le maillon défaillant si une commande ne produit rien.
        func logPress(_ nom: String) {
            Task { @MainActor in self.engine?.log("🎮 bouton \(nom) appuyé") }
        }

        // Sticks → consignes PCMD (zone morte de 15 % — la manette de
        // l'utilisateur dérive légèrement au repos)
        func axis(_ v: Float) -> Int {
            abs(v) < 0.15 ? 0 : Int(v * 100)
        }
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.yaw = axis(x); self?.gaz = axis(y)
        }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            self?.roll = axis(x); self?.pitch = axis(y)
        }
        // Boutons
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { logPress("✕ (décoller/atterrir)"); Task { @MainActor in
                self?.engine?.manualButton(takeoffLand: true) } }
        }
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { logPress("○ (URGENCE)"); Task { @MainActor in
                self?.engine?.emergencyAll() } }
        }
        pad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { logPress("□ (photo)"); Task { @MainActor in
                guard let e = self?.engine, let d = e.manualTarget else { return }
                e.send(.takePicture, to: d) } }
        }
        pad.leftShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { logPress("L1 (LED éteintes)"); Task { @MainActor in
                self?.engine?.manualLeds(intensity: 0) } }
        }
        pad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { logPress("R1 (LED 100 %)"); Task { @MainActor in
                self?.engine?.manualLeds(intensity: 100) } }
        }
        // △ = LEDs 100 % aussi (secours de R1)
        pad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { logPress("△ (LED 100 %)"); Task { @MainActor in
                self?.engine?.manualLeds(intensity: 100) } }
        }
        // ◄ ► = reprendre le contrôle du drone précédent / suivant
        // (parmi ceux en mode Manuel) — la convention du cockpit Drone PS5.
        pad.dpad.left.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { logPress("◄ (drone précédent)"); Task { @MainActor in
                self?.engine?.cycleManualTarget(-1) } }
        }
        pad.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { logPress("► (drone suivant)"); Task { @MainActor in
                self?.engine?.cycleManualTarget(1) } }
        }

        // Flux PCMD ~10 Hz vers le drone ciblé
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1,
                                     repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.engine?.manualInput(roll: self.roll, pitch: self.pitch,
                                         yaw: self.yaw, gaz: self.gaz)
            }
        }
    }
}

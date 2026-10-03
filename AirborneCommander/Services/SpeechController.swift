import Foundation
import Speech
import AVFoundation
import Observation

// MARK: - SpeechController : pilotage de la flotte à la VOIX
//
// Reconnaissance vocale française (Speech framework) + micro (AVAudioEngine).
// Chaque phrase terminée est transformée en UNE commande de vol par
// FleetEngine.handleVoice (« décolle », « avance », « photo », « urgence »…).
// Écoute en continu tant que le bouton est actif. Les commandes de VOL
// restent soumises à l'interrupteur « Pilotage autorisé » du téléphone —
// la voix passe par le même chemin sécurisé que la manette.
@MainActor
@Observable
final class SpeechController {

    var listening = false
    var lastPhrase = ""
    var status = "inactif"

    @ObservationIgnored weak var engine: FleetEngine?
    @ObservationIgnored private let recognizer =
        SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))
    @ObservationIgnored private let audio = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    init(engine: FleetEngine) { self.engine = engine }

    func toggle() { listening ? stop() : start() }

    // MARK: Démarrage (demande les autorisations puis écoute)

    func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            Task { @MainActor in
                guard let self else { return }
                guard auth == .authorized else {
                    self.status = "reconnaissance vocale refusée"
                    self.engine?.log("🎙️ Écoute vocale refusée — autorise « "
                        + "Reconnaissance vocale » et « Microphone » dans "
                        + "Réglages Système → Confidentialité et sécurité.")
                    return
                }
                self.requestMic()
            }
        }
    }

    private func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.status = "micro refusé"
                    self.engine?.log("🎙️ Micro refusé — autorise le micro dans "
                        + "Réglages Système → Confidentialité et sécurité.")
                    return
                }
                self.beginAudio()
            }
        }
    }

    private func beginAudio() {
        guard let recognizer, recognizer.isAvailable else {
            status = "reconnaissance vocale indisponible"
            engine?.log("🎙️ Reconnaissance vocale indisponible sur ce Mac.")
            return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = false        // on agit sur la phrase finie
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true    // hors-ligne, plus rapide
        }
        request = req

        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024,
                         format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        if !audio.isRunning {                 // ne pas relancer un moteur déjà actif
            audio.prepare()
            do {
                try audio.start()
            } catch {
                status = "micro indisponible"
                engine?.log("🎙️ Micro indisponible : \(error.localizedDescription)")
                return
            }
        }
        if !listening {                       // message une seule fois (pas à chaque phrase)
            listening = true
            status = "à l'écoute…"
            engine?.log("🎙️ Écoute ACTIVÉE — LIA (Claude) pilote air+sol+gardien. "
                + "Ex. : « décolle le groupe A », « connecte le Master S1 », "
                + "« arme Gardien et active la caméra », « urgence ». "
                + "Codes de désarmement = saisie manuelle uniquement.")
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result, result.isFinal {
                    let phrase = result.bestTranscription.formattedString
                    if !phrase.isEmpty {
                        self.lastPhrase = phrase
                        _ = self.engine?.handleVoice(phrase)
                    }
                }
                // Phrase terminée ou erreur → on relance l'écoute suivante.
                if error != nil || (result?.isFinal ?? false) {
                    if self.listening { self.beginAudio() }
                }
            }
        }
    }

    // MARK: Arrêt

    func stop() {
        listening = false
        status = "inactif"
        task?.cancel(); task = nil
        request?.endAudio(); request = nil
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
        engine?.log("🎙️ Écoute vocale arrêtée.")
    }
}

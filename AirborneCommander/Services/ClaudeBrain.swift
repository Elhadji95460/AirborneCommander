import Foundation
import Observation

// MARK: - ClaudeBrain : le cerveau IA de la flotte (API Claude)
//
// Branche l'API Claude (https://api.anthropic.com/v1/messages) sur le poste de
// commandement. Sert au RAISONNEMENT stratégique — JAMAIS dans la boucle de
// pilotage 10 Hz : analyse des photos du sol (vision) et débrief
// d'apprentissage après chaque vol.
//
// Sans clé API, TOUT continue de tourner sur l'IA LOCALE (VisionAI + mémoire
// de secteurs) : Claude n'est qu'un sur-cerveau optionnel qui affine les
// décisions quand il est disponible — exactement ce que demande le prompt
// système (« si l'API n'est pas disponible, continue avec les ressources
// locales »).
//
// SÉCURITÉ : la clé API est saisie par l'utilisateur dans le poste de
// commandement et stockée localement sur CE Mac (UserDefaults). Elle n'est
// JAMAIS journalisée ni ré-affichée, et n'est transmise qu'à l'API d'Anthropic.
@MainActor
@Observable
final class ClaudeBrain {

    static let shared = ClaudeBrain()

    // Modèle par défaut : le plus capable (raisonnement + vision).
    static let model = "claude-opus-4-8"
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// Le prompt système fourni par le commandant — l'identité du cerveau.
    static let systemPrompt = """
    Tu es LIA, le cerveau unique d'Airborne Commander — poste de commandement \
    multi-domaines d'Elhadji.

    Domaines sous ton contrôle :
    1) AÉRIEN — drones Parrot (décollage, atterrissage, pcmd, photo, LEDs, \
       missions de groupe, urgence).
    2) TERRESTRE — robot DJI RoboMaster S1 « Master S1 » (connexion Wi‑Fi \
       Direct, châssis, gimbal, blaster, LEDs, stop, patrouille).
    3) SÉCURITÉ — Gardien (armer surveillance, caméra, scan salle multi-visages, \
       ouvrir l'app Mac, statut).

    Tu reçois des ORDRES en français (voix ou texte). Tu réponds UNIQUEMENT \
    par un objet JSON valide (pas de markdown, pas de texte hors JSON) :
    {
      "reply": "phrase courte radio à afficher",
      "orders": [
        {"domain":"fleet|drone|s1|gardien","action":"...","params":{}}
      ]
    }

    Actions autorisées :
    - fleet: emergency_all | launch_group | land_group
      params: group ("A"|"B"|"C"|"D") pour launch/land
    - drone: take_off | land | emergency | photo | leds | pcmd | set_mode
      params: drone (id ou nom optionnel), roll/pitch/yaw/gaz (-100..100),
              intensity (0..100), mode ("ia"|"semi"|"manuel")
    - s1: connect | disconnect | stop | patrol | fire | gimbal_center |
          chassis | mode | led
      params: x/y m/s, z deg/s, mode ("free"|"chassis_lead"|"gimbal_lead"),
              r/g/b (0..255)
    - gardien: wake_camera | open_app | arm | status | copy_url
      (wake_camera active caméra + identification multi-personnes si besoin)

    RÈGLE ABSOLUE DE SÉCURITÉ (non négociable) :
    - Tu ne dois JAMAIS désarmer Gardien, ni envoyer, inventer, deviner ou \
      demander un code de désarmement.
    - Interdit : desarmer, disarm, code, pin, password, set_code, changer_code.
    - Seul le propriétaire humain peut saisir le code de désarmement dans \
      l'interface Gardien / téléphone.
    - En cas d'intrusion : armer, caméra, scan salle, alerter — mais JAMAIS \
      désarmer.

    Sécurité vol/sol : priorité personnes et matériel. Urgence si risque.
    Style : concis, radio, français.
    """

    // État observé par l'UI (aucune donnée sensible).
    var lastAssessment: String?
    var lastDebrief: String?
    var lastError: String?
    var thinking = false            // un appel API est en cours

    /// Journalisation (branchée sur le journal du FleetEngine). Ne reçoit
    /// JAMAIS la clé API.
    @ObservationIgnored var onLog: ((String) -> Void)?

    /// Présence de la clé — propriété OBSERVÉE (rafraîchit l'UI au changement).
    private(set) var hasKey: Bool =
        !(UserDefaults.standard.string(forKey: "claudeAPIKey") ?? "").isEmpty

    var apiKey: String {
        UserDefaults.standard.string(forKey: "claudeAPIKey") ?? ""
    }
    var enabled: Bool { hasKey }

    /// Résumé pour l'UI, sans jamais révéler la clé.
    var maskedKey: String {
        let k = apiKey
        guard k.count > 8 else { return k.isEmpty ? "—" : "•••" }
        return String(k.prefix(6)) + "…" + String(k.suffix(4))
    }

    /// Enregistre (et persiste) la clé — jamais journalisée ni affichée.
    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: "claudeAPIKey")
        hasKey = !trimmed.isEmpty
        lastError = nil
        onLog?(trimmed.isEmpty
               ? "🧠 Cerveau Claude désactivé (clé effacée) — IA locale seule."
               : "🧠 Cerveau Claude ACTIVÉ — analyse d'images et débrief par "
                 + "l'API.")
    }

    // MARK: - Analyse du sol (vision) -----------------------------------------

    struct GroundAssessment {
        let verdict: String          // « dégagé » | « encombré »
        let obstacles: [String]      // libellés courts
        let action: String           // explorer_plus | retour | prudence
        let altitudeCible: Double?   // m (surtout en extérieur)
        let raison: String
    }

    /// Analyse une photo de la caméra verticale et rend un verdict raisonné.
    /// Retourne nil sans clé, ou en cas d'échec → l'appelant garde l'IA locale.
    func analyzeGround(jpeg: Data, drone: String,
                       environment: String, secteur: String?,
                       battery: Int?) async -> GroundAssessment? {
        guard enabled else { return nil }
        let b64 = jpeg.base64EncodedString()
        let contexte = """
        Voici une photo prise par la caméra VERTICALE (vers le sol) du drone \
        \(drone). Contexte : environnement \(environment)\
        \(secteur.map { ", secteur exploré « \($0) »" } ?? "")\
        \(battery.map { ", batterie \($0) %" } ?? "").
        Évalue l'encombrement du sol et le risque d'obstacle pour ce mini-drone.
        Réponds UNIQUEMENT par un objet JSON, sans texte autour, de la forme :
        {"verdict":"dégagé|encombré","obstacles":["…"],\
        "action":"explorer_plus|retour|prudence",\
        "altitude_cible_m":<nombre ou null>,"raison":"une phrase courte"}
        """
        let content: [[String: Any]] = [
            ["type": "image",
             "source": ["type": "base64", "media_type": "image/jpeg",
                        "data": b64]],
            ["type": "text", "text": contexte],
        ]
        guard let text = await call(messages: [["role": "user",
                                                "content": content]],
                                    maxTokens: 700) else { return nil }
        guard let obj = Self.firstJSONObject(in: text) else {
            lastError = "Réponse Claude illisible (JSON attendu)."
            return nil
        }
        let verdict = (obj["verdict"] as? String) ?? "dégagé"
        let obstacles = (obj["obstacles"] as? [String]) ?? []
        let action = (obj["action"] as? String) ?? "prudence"
        let alt = obj["altitude_cible_m"] as? Double
            ?? (obj["altitude_cible_m"] as? Int).map(Double.init)
        let raison = (obj["raison"] as? String) ?? ""
        return GroundAssessment(verdict: verdict, obstacles: obstacles,
                                action: action, altitudeCible: alt,
                                raison: raison)
    }

    // MARK: - Débrief d'apprentissage après le vol ----------------------------

    /// Demande un court retour d'expérience (ce qui a marché / erreurs /
    /// amélioration). Retourne nil sans clé ou en cas d'échec.
    func debrief(context: String) async -> String? {
        guard enabled else { return nil }
        let prompt = """
        Débrief de vol. \(context)
        En 2 ou 3 phrases MAXIMUM : ce qui a bien fonctionné, une erreur ou un \
        risque éventuel, et UNE amélioration concrète pour le prochain vol. \
        Style radio, concis, pas de listes.
        """
        let text = await call(messages: [["role": "user", "content": prompt]],
                              maxTokens: 400)
        if let text { lastDebrief = text }
        return text
    }

    // MARK: - Pilotage par ordres (voix / texte) -------------------------------

    struct CommandPlan {
        let reply: String
        let orders: [[String: Any]]
    }

    /// Interprète un ordre naturel via Claude → plan d'actions JSON.
    /// Retourne nil sans clé / échec (l'appelant bascule sur l'IA locale).
    func interpretOrder(_ phrase: String, situation: String) async -> CommandPlan? {
        guard enabled else { return nil }
        let prompt = """
        SITUATION ACTUELLE :
        \(situation)

        ORDRE DU COMMANDANT :
        \(phrase)

        Réponds UNIQUEMENT par le JSON demandé (reply + orders). \
        Rappel : AUCUN code de désarmement, AUCUN desarmer.
        """
        guard let text = await call(messages: [["role": "user", "content": prompt]],
                                    maxTokens: 900) else { return nil }
        guard let obj = Self.firstJSONObject(in: text) else {
            lastError = "Ordre Claude : JSON illisible."
            return nil
        }
        let reply = (obj["reply"] as? String) ?? "Compris."
        let orders = (obj["orders"] as? [[String: Any]]) ?? []
        lastAssessment = reply
        return CommandPlan(reply: reply, orders: orders)
    }

    // MARK: - Appel HTTP brut (pas de SDK Swift officiel) ---------------------

    /// Envoie une requête Messages et renvoie le texte concaténé, ou nil.
    private func call(messages: [[String: Any]], maxTokens: Int) async -> String? {
        let key = apiKey
        guard !key.isEmpty else { return nil }
        thinking = true
        defer { thinking = false }

        var req = URLRequest(url: Self.endpoint, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")         // jamais loguée
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": maxTokens,
            "system": Self.systemPrompt,
            "messages": messages,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else {
                // Message clair SANS jamais divulguer la clé.
                let apiMsg = (try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any])?["error"]
                    .flatMap { ($0 as? [String: Any])?["message"] as? String }
                let hint = http.statusCode == 401
                    ? "clé API invalide ou expirée"
                    : (apiMsg ?? "code \(http.statusCode)")
                lastError = "Cerveau Claude : \(hint)."
                onLog?("⚠️ Cerveau Claude indisponible (\(hint)) — bascule sur "
                       + "l'IA locale.")
                return nil
            }
            lastError = nil
            guard let obj = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else { return nil }
            // Refus de sécurité éventuel → on retombe sur le local.
            if obj["stop_reason"] as? String == "refusal" { return nil }
            let blocks = obj["content"] as? [[String: Any]] ?? []
            let text = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            lastError = "Cerveau Claude : réseau — \(error.localizedDescription)."
            onLog?("⚠️ Cerveau Claude injoignable — IA locale conservée.")
            return nil
        }
    }

    /// Extrait le premier objet JSON d'un texte (Claude peut l'encadrer).
    private static func firstJSONObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else { return nil }
        return obj
    }
}

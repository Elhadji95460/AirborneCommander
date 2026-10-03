import Foundation
import Observation

// MARK: - MLP : réseau de neurones multicouche ÉVOLUTIF (backprop + croissance)
//
// RÈGLE D'OR (non négociable) :
//   À chaque cycle d'apprentissage, le réseau DOIT évoluer d'au moins une
//   façon :
//     • NEUROGENÈSE — un neurone pousse, ou
//     • DÉCONNEXION — des synapses faibles sont coupées (poids → 0), ou
//     • ÉLAGAGE — un neurone inactif est retiré.
//   Jamais de stagnation : pas de réseau figé « mort ».
//
// Réseau feed-forward (tanh caché, sigmoïde en sortie) + backprop + L2.
struct MLP: Codable {
    var sizes: [Int]
    var w: [[[Double]]]        // w[couche][sortie j][entrée i]
    var b: [[Double]]          // b[couche][sortie j]
    /// Nombre de synapses coupées depuis la création (compteur d'affichage).
    var disconnections: Int = 0

    init(_ sizes: [Int]) {
        self.sizes = sizes
        w = []; b = []
        for l in 1..<sizes.count {
            let nIn = sizes[l - 1], nOut = sizes[l]
            let scale = (2.0 / Double(nIn)).squareRoot()
            w.append((0..<nOut).map { _ in
                (0..<nIn).map { _ in Double.random(in: -1...1) * scale } })
            b.append([Double](repeating: 0, count: nOut))
        }
    }

    private func act(_ x: Double, output: Bool) -> Double {
        output ? 1 / (1 + exp(-x)) : tanh(x)
    }
    private func dAct(_ a: Double, output: Bool) -> Double {
        output ? a * (1 - a) : (1 - a * a)
    }

    func forward(_ x: [Double]) -> [[Double]] {
        var acts: [[Double]] = [x]
        for l in 0..<w.count {
            let isOut = (l == w.count - 1)
            let prev = acts[l]
            var layer = [Double](repeating: 0, count: sizes[l + 1])
            for j in 0..<sizes[l + 1] {
                var z = b[l][j]
                let wj = w[l][j]
                for i in 0..<prev.count { z += wj[i] * prev[i] }
                layer[j] = act(z, output: isOut)
            }
            acts.append(layer)
        }
        return acts
    }

    func output(_ x: [Double]) -> [Double] { forward(x).last ?? [] }

    /// Un pas de rétropropagation. `wd` = décroissance synaptique (petit L2) :
    /// les connexions inutiles s'affaiblissent d'elles-mêmes → élagage possible.
    mutating func train(_ x: [Double], _ y: [Double], lr: Double, wd: Double) {
        let acts = forward(x)
        let L = w.count
        var deltas = [[Double]](repeating: [], count: L)
        let aOut = acts[L]
        deltas[L - 1] = (0..<aOut.count).map { j in
            (aOut[j] - y[j]) * dAct(aOut[j], output: true)
        }
        if L >= 2 {
            for l in stride(from: L - 2, through: 0, by: -1) {
                let aL = acts[l + 1]
                let nextW = w[l + 1]
                let nextDelta = deltas[l + 1]
                deltas[l] = (0..<aL.count).map { i in
                    var s = 0.0
                    for j in 0..<nextDelta.count { s += nextW[j][i] * nextDelta[j] }
                    return s * dAct(aL[i], output: false)
                }
            }
        }
        for l in 0..<L {
            let prev = acts[l]
            for j in 0..<w[l].count {
                let dj = deltas[l][j]
                for i in 0..<prev.count {
                    w[l][j][i] -= lr * (dj * prev[i] + wd * w[l][j][i])
                }
                b[l][j] -= lr * dj
            }
        }
    }

    // MARK: Évolution de l'architecture

    /// Fait POUSSER un neurone dans la couche cachée H (neurogenèse). Entrées
    /// aléatoires faibles, sorties quasi neutres : il se laisse « recruter »
    /// progressivement par l'entraînement sans perturber l'existant.
    mutating func growHidden(_ H: Int) {
        guard H >= 1, H <= sizes.count - 2 else { return }
        let nIn = sizes[H - 1]
        let scaleIn = (2.0 / Double(nIn)).squareRoot()
        w[H - 1].append((0..<nIn).map { _ in Double.random(in: -1...1) * scaleIn })
        b[H - 1].append(0)
        for j in 0..<w[H].count { w[H][j].append(Double.random(in: -0.05...0.05)) }
        sizes[H] += 1
    }

    /// Retire le neurone d de la couche cachée H (élagage synaptique).
    mutating func pruneHidden(_ H: Int, _ d: Int) {
        guard H >= 1, H <= sizes.count - 2, sizes[H] > 4, d < sizes[H] else { return }
        w[H - 1].remove(at: d)
        b[H - 1].remove(at: d)
        for j in 0..<w[H].count { w[H][j].remove(at: d) }
        sizes[H] -= 1
    }

    /// Coupe les synapses trop faibles (|w| < seuil) → déconnexion réelle.
    /// Retourne le nombre de liens coupés (règle d'or : déconnexions).
    @discardableResult
    mutating func disconnectWeak(threshold: Double = 0.012) -> Int {
        var n = 0
        for l in 0..<w.count {
            for j in 0..<w[l].count {
                for i in 0..<w[l][j].count {
                    if abs(w[l][j][i]) > 0, abs(w[l][j][i]) < threshold {
                        w[l][j][i] = 0
                        n += 1
                    }
                }
            }
        }
        disconnections += n
        return n
    }

    /// Force au moins une déconnexion : coupe la synapse la plus faible non nulle.
    @discardableResult
    mutating func forceOneDisconnection() -> Bool {
        var bestAbs = Double.greatestFiniteMagnitude
        var best: (Int, Int, Int)?
        for l in 0..<w.count {
            for j in 0..<w[l].count {
                for i in 0..<w[l][j].count {
                    let a = abs(w[l][j][i])
                    if a > 1e-12, a < bestAbs {
                        bestAbs = a
                        best = (l, j, i)
                    }
                }
            }
        }
        guard let (l, j, i) = best else { return false }
        w[l][j][i] = 0
        disconnections += 1
        return true
    }
}

// MARK: - NeuralMemory : cerveau neuronal ÉVOLUTIF de la flotte
//
// RÈGLE D'OR : après chaque apprentissage, il y a TOUJOURS soit des neurones
// qui poussent, soit des déconnexions (synapses coupées / neurones élagués).
// Jamais de cycle « rien ne change ».
@MainActor
@Observable
final class NeuralMemory {

    static let shared = NeuralMemory()

    /// Texte de la règle d'or (UI / journal).
    static let regleOr = "Règle d'or : toujours des déconnexions entre neurones, ou des neurones qui poussent."

    static let inputs = ["sect_nord", "sect_est", "sect_ouest", "sect_sud",
                         "env_int", "env_ext", "bat_haut", "bat_bas"]
    static let outputs = ["explorer", "risque"]
    static let label: [String: String] = [
        "sect_nord": "Nord", "sect_est": "Est", "sect_ouest": "Ouest",
        "sect_sud": "Sud", "env_int": "Intérieur", "env_ext": "Extérieur",
        "bat_haut": "Batterie +", "bat_bas": "Batterie −",
        "explorer": "Explorer", "risque": "Risque",
    ]

    var net = MLP([8, 8, 6, 2])
    var layerActivations: [[Double]] = []
    var trainings = 0
    var neurons: Int { net.sizes.reduce(0, +) }      // total (affichage)
    var lastEvolution: String = NeuralMemory.regleOr

    /// Évènements d'évolution (neurogenèse / élagage) → journal de la flotte.
    @ObservationIgnored var onEvent: ((String) -> Void)?

    struct Sample: Codable { var x: [Double]; var y: [Double] }
    @ObservationIgnored private var replay: [Sample] = []
    @ObservationIgnored private let lr = 0.06
    @ObservationIgnored private let wd = 0.0006          // décroissance synaptique
    @ObservationIgnored private let epochs = 30
    @ObservationIgnored private let replayCap = 300
    // Paramètres d'évolution
    @ObservationIgnored private var lossHistory: [Double] = []
    @ObservationIgnored private var lastGrow = -10
    @ObservationIgnored private var lastPrune = -10
    @ObservationIgnored private var growCursor = 0
    @ObservationIgnored private let maxTotalHidden = 44
    @ObservationIgnored private let maxPerLayer = 22

    private init() {
        layerActivations = net.forward(zeros)
        load()
    }

    private var zeros: [Double] { [Double](repeating: 0, count: Self.inputs.count) }
    private func vector(_ f: Set<String>) -> [Double] {
        Self.inputs.map { f.contains($0) ? 1.0 : 0.0 }
    }
    var archString: String { net.sizes.map(String.init).joined(separator: "·") }
    private var totalHidden: Int {
        net.sizes.count > 2 ? net.sizes[1..<(net.sizes.count - 1)].reduce(0, +) : 0
    }

    var output: [String: Double] {
        let o = layerActivations.last ?? [0.5, 0.5]
        return ["explorer": o.first ?? 0.5, "risque": o.count > 1 ? o[1] : 0.5]
    }
    var sizes: [Int] { net.sizes }

    // MARK: Apprentissage + évolution

    func reinforce(features: Set<String>, explorer: Double, risque: Double) {
        replay.append(Sample(x: vector(features), y: [explorer, risque]))
        if replay.count > replayCap { replay.removeFirst(replay.count - replayCap) }
        var n = net
        for _ in 0..<epochs {
            for s in replay.shuffled() { n.train(s.x, s.y, lr: lr, wd: wd) }
        }
        net = n
        trainings += 1
        let loss = averageLoss()
        lossHistory.append(loss)
        if lossHistory.count > 12 { lossHistory.removeFirst() }
        evolve(loss: loss)                       // neurogenèse / élagage
        layerActivations = net.forward(vector(features))
        save()
    }

    private func averageLoss() -> Double {
        guard !replay.isEmpty else { return 0 }
        var s = 0.0
        for smp in replay {
            let o = net.output(smp.x)
            for j in 0..<min(o.count, smp.y.count) {
                let e = o[j] - smp.y[j]; s += e * e
            }
        }
        return s / Double(replay.count)
    }

    /// Remodèle l'architecture — RÈGLE D'OR : toujours pousse OU déconnexion.
    private func evolve(loss: Double) {
        var didEvolve = false

        // 1) DÉCONNEXIONS synaptiques (toujours tenter — affaiblit les liens morts)
        let cut = net.disconnectWeak(threshold: 0.012)
        if cut > 0 {
            didEvolve = true
            lastEvolution = "✂️ \(cut) déconnexion(s) synaptique(s) — \(archString)"
            onEvent?("✂️ Règle d'or : \(cut) connexion(s) coupée(s) entre neurones "
                + "(réseau \(archString), total coupures \(net.disconnections)).")
        }

        // 2) NEUROGENÈSE : erreur encore présente → un neurone pousse
        if trainings - lastGrow >= 2, totalHidden < maxTotalHidden, loss > 0.012 {
            let hidden = Array(1..<(net.sizes.count - 1))
            if !hidden.isEmpty {
                var tries = 0
                var H = hidden[growCursor % hidden.count]
                while net.sizes[H] >= maxPerLayer && tries < hidden.count {
                    growCursor += 1; H = hidden[growCursor % hidden.count]; tries += 1
                }
                if net.sizes[H] < maxPerLayer {
                    net.growHidden(H); growCursor += 1; lastGrow = trainings
                    didEvolve = true
                    lastEvolution = "🌱 Neurone poussé (couche \(H)) — \(archString)"
                    onEvent?("🌱 Règle d'or : un neurone a poussé (couche \(H)) — "
                        + "réseau \(archString).")
                }
            }
        }

        // 3) ÉLAGAGE de neurone inactif
        if trainings - lastPrune >= 2 {
            for H in 1..<(net.sizes.count - 1) where net.sizes[H] > 4 {
                for d in 0..<net.sizes[H] {
                    var l1 = 0.0
                    for j in 0..<net.w[H].count { l1 += abs(net.w[H][j][d]) }
                    if l1 < 0.015 {
                        net.pruneHidden(H, d); lastPrune = trainings
                        didEvolve = true
                        lastEvolution = "✂️ Neurone élagué (couche \(H)) — \(archString)"
                        onEvent?("✂️ Règle d'or : neurone inactif retiré (couche \(H)) — "
                            + "réseau \(archString).")
                        break
                    }
                }
                if lastPrune == trainings { break }
            }
        }

        // 4) GARANTIE RÈGLE D'OR : si rien n'a bougé → forcer au moins une déconnexion
        //    ou une pousse (priorité déconnexion pour ne pas exploser la taille).
        if !didEvolve {
            if net.forceOneDisconnection() {
                lastEvolution = "✂️ Déconnexion forcée (règle d'or) — \(archString)"
                onEvent?("✂️ Règle d'or respectée : déconnexion forcée entre neurones "
                    + "(réseau \(archString)).")
            } else if totalHidden < maxTotalHidden {
                let hidden = Array(1..<(net.sizes.count - 1))
                if let H = hidden.first(where: { net.sizes[$0] < maxPerLayer }) {
                    net.growHidden(H); lastGrow = trainings
                    lastEvolution = "🌱 Pousse forcée (règle d'or) — \(archString)"
                    onEvent?("🌱 Règle d'or respectée : un neurone a poussé "
                        + "(couche \(H)) — réseau \(archString).")
                }
            }
        }
    }

    // MARK: Décision

    func orderedSectors(environment env: String) -> [Int] {
        let secteurs = ["sect_nord", "sect_est", "sect_ouest", "sect_sud"]
        let envF = env == "Extérieur" ? "env_ext" : "env_int"
        return secteurs.enumerated().map { (i, s) -> (Int, Double) in
            let o = net.output(vector([s, envF, "bat_haut"]))
            return (i, (o.first ?? 0.5) - (o.count > 1 ? o[1] : 0.5))
        }.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    // MARK: Activation vivante

    func observe(sector: String?, environment env: String, battery: Int?) {
        var f = Set<String>()
        let m = ["nord": "sect_nord", "est": "sect_est",
                 "ouest": "sect_ouest", "sud": "sect_sud"]
        if let s = sector, let k = m[s] { f.insert(k) }
        f.insert(env == "Extérieur" ? "env_ext" : "env_int")
        if let b = battery { f.insert(b >= 50 ? "bat_haut" : "bat_bas") }
        layerActivations = net.forward(vector(f))
    }

    // MARK: Persistance

    @ObservationIgnored private var file: URL? {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("AirborneCommander",
                                              isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("neurones.json")
    }
    private struct Snapshot: Codable {
        var net: MLP; var replay: [Sample]; var trainings: Int
    }
    private func save() {
        guard let f = file, let d = try? JSONEncoder().encode(
            Snapshot(net: net, replay: replay, trainings: trainings)) else { return }
        try? d.write(to: f, options: .atomic)
    }
    private func load() {
        // Accepte une architecture ÉVOLUÉE (tailles cachées différentes) tant
        // que les entrées/sorties correspondent.
        guard let f = file, let d = try? Data(contentsOf: f),
              let s = try? JSONDecoder().decode(Snapshot.self, from: d),
              s.net.sizes.first == net.sizes.first,
              s.net.sizes.last == net.sizes.last else { return }
        net = s.net; replay = s.replay; trainings = s.trainings
        layerActivations = net.forward(zeros)
    }
}

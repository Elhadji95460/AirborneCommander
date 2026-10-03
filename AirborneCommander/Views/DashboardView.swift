import SwiftUI

// MARK: - Thème « console de commandement »
extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
    static let cmdBackground = Color(hex: 0x0A0E14)   // fond général
    static let cmdPanel = Color(hex: 0x121A26)        // panneaux
    static let cmdCard = Color(hex: 0x1A2432)         // cartes drone
    static let cmdNeon = Color(hex: 0x00FF9F)         // accent principal
    static let cmdAmber = Color(hex: 0xFFB020)        // avertissements
    static let cmdRed = Color(hex: 0xFF3B5C)          // urgence
}

// MARK: - DASHBOARD V5 : sidebar de commandement + grille des groupes
struct DashboardView: View {
    @State private var engine = FleetEngine.shared
    @State private var pad: DualSenseManager?
    @State private var speech: SpeechController?
    @State private var showKeySheet = false
    @State private var keyDraft = ""
    @State private var aiOrder = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 290)
            Divider().overlay(Color.cmdNeon.opacity(0.15))
            mainArea
        }
        .background(Color.cmdBackground)
        .preferredColorScheme(.dark)
        .onAppear {
            _ = engine.server                       // démarre le WebSocket
            if pad == nil { pad = DualSenseManager(engine: engine) }
            if speech == nil { speech = SpeechController(engine: engine) }
        }
        .sheet(isPresented: $showKeySheet) { keySheet }
    }

    // MARK: - Panneau Master S1 (terrestre)
    private var masterS1Panel: some View {
        let s1 = engine.masterS1
        let u = s1.unit
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TERRESTRE · MASTER S1")
                    .font(.caption2.bold().monospaced())
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text(u.model)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(u.connected ? Color.cmdNeon
                          : (u.state == .connecting ? Color.cmdAmber : Color.cmdRed))
                    .frame(width: 8, height: 8)
                Text("\(u.name) · \(u.state.rawValue)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(u.connected ? .white : .white.opacity(0.55))
                    .lineLimit(1)
            }
            Text(u.statusDetail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
            if let bat = u.battery {
                Text("Batterie \(bat) %")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(bat < 25 ? Color.cmdRed : Color.cmdNeon.opacity(0.85))
            }
            Text("IP \(u.ip) · port 40923")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))

            // Modes
            Picker("", selection: Binding(
                get: { u.robotMode },
                set: { s1.setMode($0) }
            )) {
                ForEach(GroundRobotMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!u.connected)

            // Commandes
            HStack(spacing: 8) {
                if u.connected {
                    Button("Stop") { s1.stopChassis() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.cmdAmber)
                    Button("Patrol") { s1.patrolDemo() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.cmdNeon)
                    Button("Fire") { s1.fire() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.cmdRed)
                    Button("Gimbal ⊙") { s1.gimbalRecenter() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                    Button("Déco") { s1.disconnect() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    Button("Connecter") { s1.connect() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.cmdNeon)
                    Button("App S1") { s1.openControllerApp() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            Text("Wi‑Fi Direct robot (RoboMaster-XXXX) · ⛔ Urgence générale = stop S1 aussi")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cmdPanel))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(u.connected ? Color.cmdNeon.opacity(0.25) : Color.clear, lineWidth: 1)
        )
    }

    // MARK: - Panneau Gardien (sécurité intégrée)
    private var gardienPanel: some View {
        let g = engine.gardien
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("GARDIEN SÉCURITÉ")
                    .font(.caption2.bold().monospaced())
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button("Rafraîchir") { g.refresh() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.cmdNeon)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(g.online
                          ? (g.arme ? Color.cmdAmber : Color.cmdNeon)
                          : Color.cmdRed)
                    .frame(width: 8, height: 8)
                Text(g.statusLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(g.online ? .white : Color.cmdRed)
                    .lineLimit(2)
            }
            if !g.remoteURL.isEmpty {
                Text(g.remoteURL)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.cmdNeon.opacity(0.85))
                    .lineLimit(1)
                    .textSelection(.enabled)
            } else if g.online {
                Text("Tunnel : en attente d'URL…")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            HStack(spacing: 8) {
                Button("Caméra") {
                    g.wakeCamera(openApp: true)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.cmdNeon)
                Button("Ouvrir app") {
                    g.openGardienApp()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                Button("Copier URL") {
                    g.copyRemoteURL()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cmdPanel))
    }

    // MARK: Fenêtre de saisie de la clé API Claude (jamais ré-affichée)
    private var keySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cerveau Claude — clé API")
                .font(.title3.bold())
            Text("Colle ta clé API Anthropic (sk-ant-…). Elle est stockée "
                 + "UNIQUEMENT sur ce Mac, jamais affichée ni journalisée, et "
                 + "n'est transmise qu'à l'API d'Anthropic. Sans clé, la flotte "
                 + "tourne sur son IA locale.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("sk-ant-…", text: $keyDraft)
                .textFieldStyle(.roundedBorder)
            if engine.brain.hasKey {
                Text("Une clé est déjà enregistrée (\(engine.brain.maskedKey)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if engine.brain.hasKey {
                    Button("Effacer la clé", role: .destructive) {
                        engine.brain.setAPIKey("")
                        keyDraft = ""; showKeySheet = false
                    }
                }
                Spacer()
                Button("Annuler") { keyDraft = ""; showKeySheet = false }
                Button("Enregistrer") {
                    engine.brain.setAPIKey(keyDraft)
                    keyDraft = ""; showKeySheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    // MARK: Sidebar : état système + urgence + journal
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AIRBORNE")
                    .font(.system(size: 26, weight: .black, design: .monospaced))
                    .foregroundStyle(Color.cmdNeon)
                Text("COMMANDER V5")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(.top, 18)

            statTile("SERVEUR",
                     engine.server.listening
                        ? "ws://\(engine.server.localIP):\(CommandServer.port)"
                        : "arrêté",
                     ok: engine.server.listening)
            // Chaque manette : nom, version de l'app, drones tenus
            VStack(alignment: .leading, spacing: 5) {
                Text("IPHONES-RELAIS (MANETTES)")
                    .font(.caption2.bold().monospaced())
                    .foregroundStyle(.white.opacity(0.45))
                if engine.phones.isEmpty {
                    HStack(spacing: 6) {
                        Circle().fill(.gray).frame(width: 8, height: 8)
                        Text("aucune connectée")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                } else {
                    ForEach(engine.phones) { p in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(p.connected ? Color.cmdNeon : Color.cmdRed)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(p.name)
                                    .font(.system(size: 12, weight: .semibold,
                                                  design: .monospaced))
                                    .foregroundStyle(p.connected ? .white
                                                     : .white.opacity(0.5))
                                    .lineLimit(1)
                                Text("app v\(p.version ?? "?") · "
                                     + "\(engine.drones.filter { $0.phone == p.name }.count) drone(s)"
                                     + (p.connected ? "" : " · déconnectée"))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(p.connected
                                                     ? Color.cmdNeon.opacity(0.8)
                                                     : Color.cmdRed.opacity(0.8))
                            }
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.cmdPanel))
            statTile("MANETTE PS5",
                     pad?.connected == true
                        ? (engine.manualTarget.map {
                            "→ \($0.name) · \(engine.lastManualInput)"
                          } ?? "connectée — aucun drone en Manuel")
                        : "non détectée",
                     ok: pad?.connected == true && engine.manualTarget != nil)
            statTile("FLOTTE",
                     "\(engine.drones.count) drone(s) · "
                     + "\(engine.drones.filter { $0.state != .grounded && $0.state != .linkLost }.count) en vol",
                     ok: !engine.drones.isEmpty)

            // Environnement de vol : intérieur (bas/lent/précis) / extérieur
            // (plafond plus haut, trajets plus longs).
            VStack(alignment: .leading, spacing: 5) {
                Text("ENVIRONNEMENT")
                    .font(.caption2.bold().monospaced())
                    .foregroundStyle(.white.opacity(0.45))
                Picker("", selection: Bindable(engine).environment) {
                    ForEach(FlightEnvironment.allCases) { e in
                        Label(e.rawValue, systemImage: e.symbol).tag(e)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(engine.environment.hint)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.cmdPanel))

            // Cerveau LIA (Claude) : ordres voix/texte sur TOUT sauf codes désarmement.
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("LIA · CLAUDE")
                        .font(.caption2.bold().monospaced())
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Button(engine.brain.hasKey ? "clé" : "Activer") {
                        keyDraft = ""; showKeySheet = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.cmdNeon)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(engine.brain.hasKey ? Color.cmdNeon : .gray)
                        .frame(width: 8, height: 8)
                    Text(engine.brain.thinking ? "réflexion…"
                         : engine.brain.hasKey
                            ? "commandes IA (air+sol+gardien)"
                         : "inactif — mots-clés locaux")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(engine.brain.hasKey ? Color.cmdNeon
                                         : .white.opacity(0.6))
                        .lineLimit(2)
                }
                if let a = engine.brain.lastAssessment {
                    Text("🧠 \(a)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(3)
                }
                // Champ d'ordre direct
                HStack(spacing: 6) {
                    TextField("Ordre LIA…", text: $aiOrder)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.35)))
                        .onSubmit { sendAIOrder() }
                    Button("▶") { sendAIOrder() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.cmdNeon)
                        .disabled(aiOrder.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Codes désarmement = humains seulement")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.cmdAmber.opacity(0.8))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.cmdPanel))

            // Contrôle vocal : piloter à la voix (« décolle », « avance »…).
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("ÉCOUTE VOCALE")
                        .font(.caption2.bold().monospaced())
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    Button(speech?.listening == true ? "Arrêter" : "Activer") {
                        speech?.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(speech?.listening == true
                                     ? Color.cmdRed : Color.cmdNeon)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(speech?.listening == true ? Color.cmdNeon : .gray)
                        .frame(width: 8, height: 8)
                    Text(speech?.status ?? "inactif")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(speech?.listening == true
                                         ? Color.cmdNeon : .white.opacity(0.6))
                        .lineLimit(1)
                }
                if let ph = speech?.lastPhrase, !ph.isEmpty {
                    Text("« \(ph) »")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.cmdPanel))

            // ── Module GARDIEN (sécurité / surveillance / téléphone) ──
            gardienPanel

            // ── Module TERRESTRE : RoboMaster S1 (Master S1) ──
            masterS1Panel

            Button {
                engine.emergencyAll()
            } label: {
                Label("URGENCE GÉNÉRALE", systemImage: "exclamationmark.octagon.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.cmdRed))
            .foregroundStyle(.white)

            Text("JOURNAL")
                .font(.caption.bold().monospaced())
                .foregroundStyle(.white.opacity(0.5))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(engine.journal.enumerated()), id: \.offset) {
                            i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.75))
                                .id(i)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: engine.journal.count) { _, n in
                    proxy.scrollTo(n - 1, anchor: .bottom)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color.cmdPanel))
        }
        .padding(14)
    }

    private func sendAIOrder() {
        let t = aiOrder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        _ = engine.handleCommand(t)
        aiOrder = ""
    }

    private func statTile(_ title: String, _ value: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.bold().monospaced())
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 6) {
                Circle().fill(ok ? Color.cmdNeon : .gray)
                    .frame(width: 8, height: 8)
                Text(value)
                    .font(.system(size: 12, weight: .medium,
                                  design: .monospaced))
                    .foregroundStyle(ok ? Color.cmdNeon : .white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cmdPanel))
    }

    /// Architecture du réseau, ex. « 8·10·6·2 ».
    private var neuralArch: String {
        engine.neural.sizes.map(String.init).joined(separator: "·")
    }

    // MARK: Zone principale : groupes + non assignés
    private var mainArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("GROUPES DE MISSION")
                        .font(.title3.bold().monospaced())
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Button {
                        engine.addDemoSquadron()
                    } label: {
                        Label("Escadrille de démo", systemImage: "plus.circle")
                    }
                    .tint(Color.cmdNeon)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380),
                                             spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 14) {
                    ForEach(engine.groups) { g in
                        GroupPanel(group: g)
                    }
                }
                if !engine.unassigned.isEmpty {
                    Text("SANS GROUPE")
                        .font(.caption.bold().monospaced())
                        .foregroundStyle(.white.opacity(0.5))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340),
                                                 spacing: 10)],
                              alignment: .leading, spacing: 10) {
                        ForEach(engine.unassigned) { d in
                            DroneCard(drone: d)
                        }
                    }
                }

                // Unités terrestres
                if !engine.groundUnits.isEmpty {
                    Text("UNITÉS TERRESTRES")
                        .font(.caption.bold().monospaced())
                        .foregroundStyle(.white.opacity(0.5))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340),
                                                 spacing: 10)],
                              alignment: .leading, spacing: 10) {
                        ForEach(engine.groundUnits) { g in
                            GroundUnitCard(unit: g, bridge: engine.masterS1)
                        }
                    }
                }

                // Réseau de neurones : réflexes appris, visualisés en direct.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("RÉSEAU DE NEURONES")
                            .font(.title3.bold().monospaced())
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Text("\(neuralArch) · \(engine.neural.neurons) neurones "
                             + "· \(engine.neural.trainings) apprentissage(s) · "
                             + "évolutif")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.cmdNeon.opacity(0.8))
                    }
                    NeuralView(brain: engine.neural)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 14)
                            .fill(Color.cmdPanel))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.cmdNeon.opacity(0.12)))
                    Text("RÈGLE D'OR : toujours des déconnexions entre neurones, "
                         + "ou des neurones qui poussent — jamais de réseau figé. "
                         + "Neurogenèse + élagage + synapses coupées à chaque "
                         + "apprentissage. \(engine.neural.lastEvolution)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Carte unité terrestre (Master S1)
struct GroundUnitCard: View {
    @Bindable var unit: GroundUnit
    var bridge: MasterS1Bridge

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "car.side.fill")
                    .foregroundStyle(Color.cmdNeon)
                Text(unit.name.uppercased())
                    .font(.headline.monospaced())
                    .foregroundStyle(.white)
                Spacer()
                Text(unit.state.rawValue)
                    .font(.caption2.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(stateColor.opacity(0.2)))
                    .foregroundStyle(stateColor)
            }
            Text(unit.model + " · " + unit.ip)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 12) {
                if let b = unit.battery {
                    Label("\(b) %", systemImage: "battery.100")
                        .foregroundStyle(b < 25 ? Color.cmdRed : Color.cmdNeon)
                }
                Text(unit.robotMode.label)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .font(.system(size: 11, design: .monospaced))

            HStack(spacing: 8) {
                if unit.connected {
                    Button("▲") { bridge.chassis(x: 0.5, y: 0, z: 0) }
                    Button("▼") { bridge.chassis(x: -0.5, y: 0, z: 0) }
                    Button("◀") { bridge.chassis(x: 0, y: -0.5, z: 0) }
                    Button("▶") { bridge.chassis(x: 0, y: 0.5, z: 0) }
                    Button("⏹") { bridge.stopChassis() }
                    Button("🔥") { bridge.fire() }
                } else {
                    Button("Connecter S1") { bridge.connect(ip: unit.ip) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.cmdNeon)
                        .foregroundStyle(.black)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!unit.connected && unit.state == .connecting)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.cmdCard))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(unit.connected ? Color.cmdNeon.opacity(0.35) : .white.opacity(0.08)))
    }

    private var stateColor: Color {
        switch unit.state {
        case .ready, .moving: Color.cmdNeon
        case .connecting: Color.cmdAmber
        case .emergency, .error: Color.cmdRed
        case .offline: .gray
        }
    }
}

// MARK: - Panneau d'un groupe : état de mission + séquencement + drones
struct GroupPanel: View {
    @State var group: DroneGroup
    @State private var engine = FleetEngine.shared

    private var members: [Drone] { engine.members(of: group) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(group.name.uppercased())
                    .font(.headline.monospaced())
                    .foregroundStyle(Color.cmdNeon)
                stateBadge
                Spacer()
                if group.missionState == .idle {
                    Button("▶ Lancer") { engine.launchGroup(group) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.cmdNeon)
                        .foregroundStyle(.black)
                        .disabled(members.isEmpty)
                } else {
                    Button("🛬 Atterrir") { engine.landGroup(group) }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.cmdAmber)
                }
            }
            // Progression du décollage séquentiel — visible en direct
            if group.missionState == .launching {
                ProgressView(value: Double(group.takeoffIndex),
                             total: Double(max(group.takeoffCount, 1))) {
                    Text("Décollage \(group.takeoffIndex)/\(group.takeoffCount) "
                         + "— un par un, mission simultanée ensuite")
                        .font(.caption.monospaced())
                        .foregroundStyle(Color.cmdAmber)
                }
                .tint(Color.cmdAmber)
            }
            // 👁 VISION DU GROUPE : ce que voient ses drones + verdict IA
            let vision = members.filter { $0.lastPhoto != nil }
            if !vision.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vision) { d in
                            if let jpeg = d.lastPhoto,
                               let ns = NSImage(data: jpeg) {
                                VStack(spacing: 2) {
                                    Image(nsImage: ns)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 108, height: 81)
                                        .clipShape(RoundedRectangle(
                                            cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8)
                                            .stroke(d.groundVerdict == "encombré"
                                                    ? Color.cmdAmber.opacity(0.7)
                                                    : Color.cmdNeon.opacity(0.4)))
                                    Text("\(d.name) · "
                                         + (d.groundVerdict.map {
                                            "sol \($0)" } ?? "—"))
                                        .font(.system(size: 9, weight: .semibold,
                                                      design: .monospaced))
                                        .foregroundStyle(
                                            d.groundVerdict == "encombré"
                                            ? Color.cmdAmber : Color.cmdNeon)
                                }
                            }
                        }
                    }
                }
            }

            if members.isEmpty {
                Text("Aucun drone — assigne-les via le menu ⚙︎ des cartes.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.vertical, 12)
            } else {
                ForEach(members) { d in DroneCard(drone: d) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.cmdPanel))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(group.missionState == .mission
                    ? Color.cmdNeon.opacity(0.5) : .white.opacity(0.07)))
    }

    private var stateBadge: some View {
        Text(group.missionState.rawValue)
            .font(.caption2.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(badgeColor.opacity(0.18)))
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        switch group.missionState {
        case .idle: .gray
        case .launching: .cmdAmber
        case .mission: .cmdNeon
        case .landing: .cmdAmber
        }
    }
}

// MARK: - Carte d'un drone : télémétrie + mode + groupe
struct DroneCard: View {
    @State var drone: Drone
    @State private var engine = FleetEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(stateColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text(drone.name).font(.headline)
                        .foregroundStyle(.white)
                    Text("\(drone.bleName ?? "—") · via \(drone.phone ?? "?")")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Text(drone.state.rawValue)
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(stateColor.opacity(0.18)))
                    .foregroundStyle(stateColor)
            }

            // Télémétrie temps réel
            HStack(spacing: 14) {
                telemetry("battery.75percent",
                          drone.battery.map { "\($0) %" } ?? "—",
                          warn: drone.batteryEmergency)
                telemetry("arrow.up.to.line", String(format: "%.1f m",
                                                     drone.altitude))
                telemetry("point.topleft.down.to.point.bottomright.curvepath",
                          String(format: "%.0f m", drone.distance))
                telemetry("antenna.radiowaves.left.and.right",
                          drone.signal.rawValue,
                          warn: drone.signal == .faible || drone.signal == .perdu)
                telemetry("wifi",
                          drone.rssi.map { "\($0) dBm" } ?? "—",
                          warn: (drone.rssi ?? 0) <= FleetEngine.handoverRSSIThreshold
                                && drone.rssi != nil)
            }

            // ↔︎ Handover en cours : qui lâche, qui sonde, qui reprend
            if let label = drone.handover.label {
                Text(label)
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.cmdAmber.opacity(0.15)))
                    .foregroundStyle(Color.cmdAmber)
            }

            // 📷 Retour image : dernière photo rapatriée (caméra verticale)
            if let jpeg = drone.lastPhoto, let ns = NSImage(data: jpeg) {
                HStack(alignment: .bottom, spacing: 8) {
                    Image(nsImage: ns)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 132, height: 99)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.cmdNeon.opacity(0.35)))
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Retour image", systemImage: "camera.fill")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.cmdNeon)
                        Text(drone.lastPhotoName ?? "photo")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                        if let date = drone.lastPhotoDate {
                            Text(date, style: .relative)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    Spacer()
                }
            }

            HStack {
                // Mode : IA 100 % / Semi-IA / Manuel (PS5) — à tout moment
                Picker("", selection: Binding(
                    get: { drone.mode },
                    set: { engine.setMode(drone, $0) })) {
                    ForEach(DroneMode.allCases) { m in
                        Image(systemName: m.symbol).tag(m)
                            .help(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)

                if drone.mode == .manual {
                    if drone === engine.manualTarget {
                        Text("🎮 cible manette")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.cmdAmber)
                    } else {
                        Button("🎮 prendre la manette") {
                            engine.manualTarget = drone
                            engine.log("🎮 La manette vise maintenant "
                                       + "\(drone.name).")
                        }
                        .buttonStyle(.plain)
                        .font(.caption2.bold())
                        .foregroundStyle(Color.cmdAmber)
                        .underline()
                    }
                }
                Spacer()
                // Récupération MANUELLE des photos (drone réel, posé)
                if !drone.isSimulated {
                    Button {
                        engine.fetchPhotosNow(drone)
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(Color.cmdNeon)
                    }
                    .buttonStyle(.plain)
                    .help("Récupérer les photos du drone maintenant (au sol)")
                }
                // Retour image PAR DRONE (📷 barré = désactivé, mémorisé)
                Button {
                    drone.photoReturnEnabled.toggle()
                    UserDefaults.standard.set(!drone.photoReturnEnabled,
                        forKey: "photoOff.\(drone.bleName ?? drone.id)")
                    if !drone.photoReturnEnabled { drone.lastPhoto = nil }
                    engine.log("📷 Retour image "
                        + (drone.photoReturnEnabled ? "activé" : "désactivé")
                        + " pour \(drone.name).")
                } label: {
                    Image(systemName: drone.photoReturnEnabled
                          ? "camera.fill" : "camera.slash.fill")
                        .foregroundStyle(drone.photoReturnEnabled
                                         ? Color.cmdNeon : .gray)
                }
                .buttonStyle(.plain)
                .help("Retour image après mission (par drone)")
                // Assignation de groupe — un seul groupe par drone
                Menu {
                    Button("Sans groupe") { engine.assign(drone, to: nil) }
                    ForEach(engine.groups) { g in
                        Button(g.name) { engine.assign(drone, to: g.id) }
                    }
                } label: {
                    Label(engine.group(id: drone.groupID)?.name ?? "Groupe…",
                          systemImage: "square.grid.2x2")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 110)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cmdCard))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(drone.batteryEmergency ? Color.cmdRed
                    : drone.mode == .manual ? Color.cmdAmber.opacity(0.6)
                    : .clear, lineWidth: 1.5))
    }

    private func telemetry(_ icon: String, _ value: String,
                           warn: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption)
            Text(value).font(.system(size: 12, weight: .semibold,
                                     design: .monospaced))
        }
        .foregroundStyle(warn ? Color.cmdRed : .white.opacity(0.8))
    }

    private var stateColor: Color {
        switch drone.state {
        case .grounded: .gray
        case .takingOff, .landing: .cmdAmber
        case .airborne, .onMission: .cmdNeon
        case .emergency, .linkLost: .cmdRed
        }
    }
}

#Preview {
    DashboardView()
        .frame(width: 1200, height: 760)
}

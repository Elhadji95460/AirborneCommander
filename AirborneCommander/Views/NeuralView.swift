import SwiftUI

// MARK: - NeuralView : visualisation VIVANTE du réseau multicouche
//
// Dessine TOUTES les couches de [[NeuralMemory]] (entrée → cachées → sortie)
// à partir de sa structure réelle. Épaisseur d'un lien = force du poids appris,
// couleur = signe (vert positif, ambre négatif), opacité = activation de la
// source. Les neurones s'allument selon le contexte courant et des impulsions
// circulent le long des liens actifs. Canvas + TimelineView pour l'animation.
struct NeuralView: View {
    var brain: NeuralMemory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 24.0)) {
            timeline in
            Canvas { ctx, size in
                render(&ctx, size, t: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(height: 320)
        .padding(.vertical, 8)
        .accessibilityLabel("Réseau de neurones multicouche de la flotte")
    }

    // Positions
    private func cx(_ col: Int, _ size: CGSize) -> CGFloat {
        let cols = brain.sizes.count
        let l: CGFloat = 164, r = size.width - 150
        return cols <= 1 ? (l + r) / 2
                         : l + (r - l) * CGFloat(col) / CGFloat(cols - 1)
    }
    private func cy(_ k: Int, _ n: Int, _ size: CGSize) -> CGFloat {
        let top: CGFloat = 28, bot = size.height - 28
        return n <= 1 ? size.height / 2
                      : top + (bot - top) * CGFloat(k) / CGFloat(n - 1)
    }
    private func glow(_ layer: Int, _ k: Int) -> Double {
        let a = brain.layerActivations
        guard layer < a.count, k < a[layer].count else { return 0 }
        return min(1, abs(a[layer][k]))
    }

    private func render(_ ctx: inout GraphicsContext, _ size: CGSize,
                        t: TimeInterval) {
        let sizes = brain.sizes
        guard sizes.count >= 2 else { return }

        // 1) Connexions entre couches adjacentes
        for l in 0..<(sizes.count - 1) {
            guard l < brain.net.w.count else { break }
            for i in 0..<sizes[l] {
                let p1 = CGPoint(x: cx(l, size), y: cy(i, sizes[l], size))
                let act = glow(l, i)
                for j in 0..<sizes[l + 1] {
                    let p2 = CGPoint(x: cx(l + 1, size),
                                     y: cy(j, sizes[l + 1], size))
                    let wgt = brain.net.w[l][j][i]
                    // Règle d'or : synapse coupée (|w|≈0) → pas de trait
                    if abs(wgt) < 1e-9 { continue }
                    let mag = min(1.0, abs(wgt) / 1.2)
                    let col: Color = wgt >= 0 ? .cmdNeon : .cmdAmber
                    let vivacite = 0.10 + 0.5 * act
                    var path = Path(); path.move(to: p1); path.addLine(to: p2)
                    ctx.stroke(path,
                        with: .color(col.opacity(0.05 + 0.5 * mag * vivacite)),
                        lineWidth: 0.4 + 2.6 * mag)
                    if act > 0.55 && mag > 0.15 && !reduceMotion {
                        let ph = CGFloat((t + Double(i) * 0.11 + Double(l) * 0.3)
                            .truncatingRemainder(dividingBy: 1.4) / 1.4)
                        let pt = CGPoint(x: p1.x + (p2.x - p1.x) * ph,
                                         y: p1.y + (p2.y - p1.y) * ph)
                        ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 2.2, y: pt.y - 2.2,
                                                        width: 4.4, height: 4.4)),
                                 with: .color(col.opacity(0.85)))
                    }
                }
            }
        }

        // 2) Neurones, couche par couche
        for (col, n) in sizes.enumerated() {
            let isInput = (col == 0), isOutput = (col == sizes.count - 1)
            for k in 0..<n {
                let p = CGPoint(x: cx(col, size), y: cy(k, n, size))
                let g = glow(col, k)
                let color: Color = (isOutput && k == 1) ? .cmdRed : .cmdNeon
                let radius: CGFloat = isInput || isOutput ? 9 : 6.5
                node(&ctx, p, radius: radius, activation: g, color: color)
                // Libellés d'entrée (gauche)
                if isInput, k < NeuralMemory.inputs.count {
                    let key = NeuralMemory.inputs[k]
                    var txt = Text(NeuralMemory.label[key] ?? key)
                        .font(.system(size: 11, design: .monospaced))
                    txt = txt.foregroundColor(.white.opacity(g > 0.5 ? 0.95 : 0.5))
                    ctx.draw(txt, at: CGPoint(x: p.x - 16, y: p.y), anchor: .trailing)
                }
                // Libellés de sortie (droite)
                if isOutput, k < NeuralMemory.outputs.count {
                    let key = NeuralMemory.outputs[k]
                    var name = Text(NeuralMemory.label[key] ?? key)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    name = name.foregroundColor(color)
                    ctx.draw(name, at: CGPoint(x: p.x + 20, y: p.y - 8), anchor: .leading)
                    var val = Text(String(format: "%.0f %%", g * 100))
                        .font(.system(size: 11, design: .monospaced))
                    val = val.foregroundColor(.white.opacity(0.6))
                    ctx.draw(val, at: CGPoint(x: p.x + 20, y: p.y + 8), anchor: .leading)
                }
            }
        }
    }

    private func node(_ ctx: inout GraphicsContext, _ p: CGPoint,
                      radius: CGFloat, activation: Double, color: Color) {
        let a = CGFloat(min(1, max(0, activation)))
        let halo = radius + 6 * a
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - halo, y: p.y - halo,
                                        width: halo * 2, height: halo * 2)),
                 with: .color(color.opacity(0.07 + 0.18 * a)))
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius,
                                        width: radius * 2, height: radius * 2)),
                 with: .color(color.opacity(0.20 + 0.66 * a)))
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius,
                                          width: radius * 2, height: radius * 2)),
                   with: .color(color.opacity(0.65)), lineWidth: 1)
    }
}

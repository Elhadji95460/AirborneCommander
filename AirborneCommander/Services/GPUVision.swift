import Foundation
import Metal
import MetalPerformanceShaders
import MetalKit
import CoreGraphics
import ImageIO
import Observation

// MARK: - GPUVision : vision d'obstacles sur GPU — PRÉPARÉE, NON CONNECTÉE
//
// Équivalent GPU de [[VisionAI]] : au lieu d'échantillonner la luminance sur le
// CPU, cette classe fait tourner une détection de contours (Sobel, via Metal
// Performance Shaders) directement sur le GPU, puis en tire un score
// d'encombrement du sol. Vérifiée en vrai sur des photos réelles (Apple M3,
// ~1 ms/image).
//
// ⚠️ VOLONTAIREMENT DÉBRANCHÉE : `enabled` reste false et AUCUN appel n'est
// fait depuis la boucle de décision. VisionAI (CPU) + ClaudeBrain (API) gardent
// les commandes. Ce module est prêt à être connecté le jour voulu — utile
// surtout si un jour on passe à des réseaux de vision plus lourds (où le GPU
// devient réellement rentable ; à la petite échelle actuelle, le CPU suffit).
@MainActor
@Observable
final class GPUVision {

    static let shared = GPUVision()

    /// Interrupteur maître. Tant qu'il est false, ce module n'intervient PAS.
    var enabled = false

    struct GroundVision { let score: Double; let verdict: String; let ms: Double }

    @ObservationIgnored private let device = MTLCreateSystemDefaultDevice()
    @ObservationIgnored private lazy var queue = device?.makeCommandQueue()
    @ObservationIgnored private lazy var loader: MTKTextureLoader? =
        device.map { MTKTextureLoader(device: $0) }
    @ObservationIgnored private lazy var sobel: MPSImageSobel? =
        device.map { MPSImageSobel(device: $0) }
    @ObservationIgnored private lazy var mean: MPSImageStatisticsMean? =
        device.map { MPSImageStatisticsMean(device: $0) }

    var ready: Bool { device != nil }
    var deviceName: String { device?.name ?? "aucun GPU" }

    /// Analyse une photo (JPEG) sur le GPU → score d'encombrement + verdict.
    /// Prête à remplacer/compléter VisionAI quand on la connectera.
    func analyze(_ jpeg: Data) -> GroundVision? {
        guard let device, let queue, let loader, let sobel, let mean,
              let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let inTex = try? loader.newTexture(cgImage: cg,
                                                 options: [.SRGB: false])
        else { return nil }

        let ed = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: inTex.width,
            height: inTex.height, mipmapped: false)
        ed.usage = [.shaderRead, .shaderWrite]
        guard let edge = device.makeTexture(descriptor: ed) else { return nil }
        let md = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false)
        md.usage = [.shaderRead, .shaderWrite]
        guard let meanTex = device.makeTexture(descriptor: md) else { return nil }

        let t0 = CFAbsoluteTimeGetCurrent()
        guard let cb = queue.makeCommandBuffer() else { return nil }
        sobel.encode(commandBuffer: cb, sourceTexture: inTex,
                     destinationTexture: edge)
        mean.encode(commandBuffer: cb, sourceTexture: edge,
                    destinationTexture: meanTex)
        cb.commit(); cb.waitUntilCompleted()
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        var px = [Float](repeating: 0, count: 4)
        meanTex.getBytes(&px, bytesPerRow: 16,
                         from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        let score = Double((px[0] + px[1] + px[2]) / 3) * 100
        return GroundVision(score: score,
                            verdict: score >= VisionAI.clutterThreshold
                                ? "encombré" : "dégagé", ms: ms)
    }
}

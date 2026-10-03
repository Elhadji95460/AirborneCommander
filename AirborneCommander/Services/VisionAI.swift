import AppKit

// MARK: - VisionAI : analyse des photos de la caméra verticale
//
// La caméra des Airborne Night regarde le SOL. L'IA estime l'encombrement du
// terrain à partir de la texture de l'image : un sol dégagé (parquet uni,
// moquette) a peu de contrastes locaux ; un sol encombré (objets, câbles,
// jouets) en a beaucoup. Méthode : échantillonnage de la luminance sur une
// grille 64×48 puis moyenne des gradients voisins — le même principe que
// l'« encombrement » calculé par le programme prouvé Drone PS5.
enum VisionAI {

    /// Seuil au-delà duquel le sol est considéré ENCOMBRÉ.
    static let clutterThreshold = 11.0

    /// Score d'encombrement (≈ 0 très uni … 30 très chargé), nil si l'image
    /// est illisible.
    static func clutterScore(_ jpeg: Data) -> Double? {
        guard let image = NSImage(data: jpeg),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              rep.pixelsWide > 4, rep.pixelsHigh > 4 else { return nil }
        let w = min(64, rep.pixelsWide)
        let h = min(48, rep.pixelsHigh)

        // Grille de luminance
        var lum = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let px = rep.colorAt(x: x * rep.pixelsWide / w,
                                     y: y * rep.pixelsHigh / h)?
                    .usingColorSpace(.deviceRGB)
                lum[y * w + x] = Double(px?.brightnessComponent ?? 0)
            }
        }
        // Moyenne des gradients horizontaux + verticaux
        var somme = 0.0
        var n = 0
        for y in 0..<h {
            for x in 1..<w {
                somme += abs(lum[y * w + x] - lum[y * w + x - 1])
                n += 1
            }
        }
        for y in 1..<h {
            for x in 0..<w {
                somme += abs(lum[y * w + x] - lum[(y - 1) * w + x])
                n += 1
            }
        }
        guard n > 0 else { return nil }
        return (somme / Double(n)) * 100
    }

    /// Verdict lisible pour le journal et les cartes.
    static func verdict(score: Double) -> String {
        score >= clutterThreshold ? "encombré" : "dégagé"
    }
}

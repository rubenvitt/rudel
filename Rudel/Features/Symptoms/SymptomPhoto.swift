import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bildaufbereitung für Symptom-Fotos.
///
/// `SymptomEntry.photoData` liegt in `.externalStorage`, landet also nicht in
/// der SQLite-Datei — das Backup wächst trotzdem mit jedem Original aus der
/// Kamera um mehrere Megabyte. Für den Zweck (Ohr, Pfote, Hautstelle beim
/// Tierarzt zeigen) genügen 1600 px Kantenlänge bei weitem.
///
/// Umgesetzt mit ImageIO statt `UIImage`: `CGImageSourceCreateThumbnailAtIndex`
/// dekodiert direkt in der Zielgröße, statt erst 12 Megapixel in den Speicher zu
/// legen, und ist nicht an den Main-Actor gebunden.
enum SymptomPhoto {
    /// Längste Kante des gespeicherten Bildes in Pixeln.
    static let maxEdgePixels = 1600
    static let jpegQuality = 0.8

    /// Verkleinert auf `maxEdgePixels` und kodiert als JPEG. `nil`, wenn die
    /// Daten kein lesbares Bild sind — dann bleibt der Aufrufer beim Original.
    static func downscaledJPEG(
        from data: Data,
        maxEdge: Int = maxEdgePixels,
        quality: Double = jpegQuality
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            // Auch erzeugen, wenn die Datei keine eingebettete Vorschau hat.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Ohne das steht ein Hochkant-Foto aus der Kamera später quer:
            // die EXIF-Orientierung wird sonst nicht in die Pixel gebacken.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]

        guard
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else { return nil }

        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }

        return output as Data
    }
}

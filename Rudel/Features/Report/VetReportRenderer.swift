import UIKit

/// Zeichnet einen `VetReportContent` als A4-PDF.
///
/// Der Fließtext ist ein `NSAttributedString`, den TextKit auf Seiten verteilt:
/// erst alle Seiten auslegen, dann zeichnen — nur so ist „Seite x von y"
/// schon auf der ersten Seite bekannt.
@MainActor
enum VetReportRenderer {

    /// A4 in Punkten.
    static let pageSize = CGSize(width: 595.2, height: 841.8)
    private static let margin: CGFloat = 52
    private static let headerHeight: CGFloat = 34
    private static let footerHeight: CGFloat = 28
    /// Sicherung gegen eine Endlosschleife, falls TextKit nichts mehr platziert.
    private static let maximumPages = 200

    private static var bodyRect: CGRect {
        CGRect(
            x: margin,
            y: margin + headerHeight,
            width: pageSize.width - 2 * margin,
            height: pageSize.height - 2 * margin - headerHeight - footerHeight
        )
    }

    static func render(_ content: VetReportContent) -> Data {
        let storage = NSTextStorage(attributedString: body(for: content))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: bodyRect.size)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            // Ein Glyphenbereich je Container erzwingt das Auslegen bis hier.
            _ = layout.glyphRange(for: container)
        } while layout.glyphRange(for: containers[containers.count - 1]).upperBound < layout.numberOfGlyphs
            && containers.count < maximumPages

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Tierarzt-Bericht \(content.pet.name)",
            kCGPDFContextCreator as String: "Rudel",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize), format: format)
        return renderer.pdfData { context in
            for (index, container) in containers.enumerated() {
                context.beginPage()
                drawHeader(content)
                let range = layout.glyphRange(for: container)
                layout.drawBackground(forGlyphRange: range, at: bodyRect.origin)
                layout.drawGlyphs(forGlyphRange: range, at: bodyRect.origin)
                drawFooter(page: index + 1, of: containers.count)
            }
        }
    }

    // MARK: Kopf und Fuß

    private static func drawHeader(_ content: VetReportContent) {
        let left = NSAttributedString(string: content.pet.name, attributes: [
            .font: serifFont(size: 13, weight: .semibold),
            .foregroundColor: Palette.ink,
        ])
        let right = NSAttributedString(string: "Tierarzt-Bericht · \(Format.date(content.generatedAt))", attributes: [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: Palette.muted,
        ])
        left.draw(at: CGPoint(x: margin, y: margin))
        let rightSize = right.size()
        right.draw(at: CGPoint(x: pageSize.width - margin - rightSize.width, y: margin + 3))

        let line = UIBezierPath()
        line.move(to: CGPoint(x: margin, y: margin + 22))
        line.addLine(to: CGPoint(x: pageSize.width - margin, y: margin + 22))
        line.lineWidth = 0.5
        Palette.line.setStroke()
        line.stroke()
    }

    private static func drawFooter(page: Int, of count: Int) {
        let text = NSAttributedString(string: "Seite \(page) von \(count)", attributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: Palette.muted,
        ])
        let size = text.size()
        text.draw(at: CGPoint(x: (pageSize.width - size.width) / 2, y: pageSize.height - margin - size.height))
        let note = NSAttributedString(string: "Erstellt mit Rudel aus eigenen Aufzeichnungen", attributes: [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: Palette.muted,
        ])
        note.draw(at: CGPoint(x: margin, y: pageSize.height - margin - size.height + 1))
    }

    // MARK: Fließtext

    private static func body(for content: VetReportContent) -> NSAttributedString {
        let text = NSMutableAttributedString()

        text.append(NSAttributedString(string: "Tierarzt-Bericht für \(content.pet.name)\n", attributes: [
            .font: serifFont(size: 22, weight: .medium),
            .foregroundColor: Palette.forest,
            .paragraphStyle: paragraph(spacingAfter: 4),
        ]))
        text.append(NSAttributedString(string: "Stand \(Format.dateTime(content.generatedAt))\n", attributes: [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: Palette.muted,
            .paragraphStyle: paragraph(spacingAfter: 6),
        ]))

        for section in content.sections {
            text.append(NSAttributedString(string: section.title + "\n", attributes: [
                .font: serifFont(size: 14, weight: .semibold),
                .foregroundColor: Palette.forest,
                .paragraphStyle: paragraph(spacingBefore: 16, spacingAfter: 5),
            ]))
            if section.rows.isEmpty {
                text.append(NSAttributedString(string: VetReportContent.emptyText + "\n", attributes: [
                    .font: UIFont.italicSystemFont(ofSize: 10),
                    .foregroundColor: Palette.muted,
                    .paragraphStyle: paragraph(spacingAfter: 2),
                ]))
                continue
            }
            for row in section.rows {
                append(row, to: text)
            }
        }
        return text
    }

    private static let labelColumn: CGFloat = 118

    private static func append(_ row: VetReportContent.Row, to text: NSMutableAttributedString) {
        let regular = UIFont.systemFont(ofSize: 10)
        // Mehrzeilige Freitexte (Fragen, Befund) im selben Absatz halten,
        // damit Folgezeilen eingerückt unter der Spalte stehen.
        var row = row
        row.text = keepInParagraph(row.text)
        row.detail = row.detail.map(keepInParagraph)
        if row.text.isEmpty {
            // Zeile ohne Spalte (Medikamente): Name fett, Angaben darunter.
            text.append(NSAttributedString(string: row.label + "\n", attributes: [
                .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: Palette.ink,
                .paragraphStyle: paragraph(spacingBefore: 3),
            ]))
        } else {
            let style = paragraph(spacingBefore: 3)
            style.tabStops = [NSTextTab(textAlignment: .left, location: labelColumn)]
            style.defaultTabInterval = labelColumn
            style.headIndent = labelColumn
            let line = NSMutableAttributedString(string: row.label + "\t", attributes: [
                .font: regular,
                .foregroundColor: Palette.muted,
                .paragraphStyle: style,
            ])
            line.append(NSAttributedString(string: row.text + "\n", attributes: [
                .font: regular,
                .foregroundColor: Palette.ink,
                .paragraphStyle: style,
            ]))
            text.append(line)
        }
        if let detail = row.detail {
            let style = paragraph(spacingAfter: 1)
            let indent = row.text.isEmpty ? 0 : labelColumn
            style.firstLineHeadIndent = indent
            style.headIndent = indent
            text.append(NSAttributedString(string: detail + "\n", attributes: [
                .font: UIFont.systemFont(ofSize: 9.5),
                .foregroundColor: Palette.muted,
                .paragraphStyle: style,
            ]))
        }
    }

    private static func keepInParagraph(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\u{2028}")
            .replacingOccurrences(of: "\n", with: "\u{2028}")
    }

    private static func paragraph(spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 0) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.paragraphSpacing = spacingAfter
        style.lineHeightMultiple = 1.15
        return style
    }

    private static func serifFont(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: serif, size: size)
    }

    /// Feste Hellwerte aus `RudelTheme`: Papier hat keinen Dunkelmodus, und die
    /// dynamischen Farben würden sich nach dem Gerätemodus richten.
    private enum Palette {
        static let forest = UIColor(red: 0x17 / 255, green: 0x3D / 255, blue: 0x33 / 255, alpha: 1)
        static let ink = UIColor(red: 0x20 / 255, green: 0x3C / 255, blue: 0x32 / 255, alpha: 1)
        static let muted = UIColor(red: 0x5D / 255, green: 0x6C / 255, blue: 0x61 / 255, alpha: 1)
        static let line = UIColor(red: 0xDE / 255, green: 0xE5 / 255, blue: 0xD9 / 255, alpha: 1)
    }
}

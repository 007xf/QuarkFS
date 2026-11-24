import AppKit
import CoreGraphics
import Foundation

/// Visual state of the QuarkFS menu-bar template glyph (candidate A from the
/// menu-bar spec). State is communicated strictly by shape, never by colour.
enum MenuBarGlyphState: String, CaseIterable, Equatable, Hashable, Sendable {
    case idle
    case busy
    case mounted
    case attention

    static func from(status: MountStatus, hasReadIssue: Bool) -> MenuBarGlyphState {
        if hasReadIssue { return .attention }
        switch status {
        case .notMounted: return .idle
        case .mounting, .unmounting: return .busy
        case .mounted: return .mounted
        case .failed: return .attention
        }
    }
}

/// Renders and caches the 22×22 pt monochrome template menu-bar glyph directly
/// from the candidate A vector geometry so both `swift build` runs and packaged
/// app bundles get crisp 1x and 2x template artwork without extra asset bundling.
enum MenuBarGlyph {
    static let artboardSize = NSSize(width: 22, height: 22)
    static let strokeWidth: CGFloat = 1.5

    @MainActor
    private static let cachedImages: [MenuBarGlyphState: NSImage] = {
        var images: [MenuBarGlyphState: NSImage] = [:]
        for state in MenuBarGlyphState.allCases {
            let image = NSImage(size: artboardSize, flipped: true) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                draw(state, in: context)
                return true
            }
            image.isTemplate = true
            images[state] = image
        }
        return images
    }()

    @MainActor
    static func image(for state: MenuBarGlyphState) -> NSImage {
        cachedImages[state]!
    }

    static func accessibilityLabel(for status: MountStatus, hasReadIssue: Bool) -> String {
        let base = "QuarkFS · \(status.title)"
        if hasReadIssue, case .failed = status { return base }
        return hasReadIssue ? "\(base) · 需要处理" : base
    }

    /// Draws the glyph in a flipped (SVG-style top-left origin) 22×22 coordinate space.
    static func draw(_ state: MenuBarGlyphState, in context: CGContext) {
        context.setStrokeColor(NSColor.black.cgColor)
        context.setFillColor(NSColor.black.cgColor)
        context.setLineWidth(strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch state {
        case .idle:
            // A-0-not-mounted.svg: closed cloud, outlined drive with slot + LED dot.
            strokePath(closedCloudPath(), in: context)
            strokePath(driveOutlinePath(), in: context)
            strokePath(driveSlotLinePath(), in: context)
            fillCircle(center: CGPoint(x: 15.4, y: 16), radius: 1, in: context)

        case .busy:
            // A-1-mounting.svg: open cloud, S-stream, outlined drive with three static dots.
            strokePath(openCloudPath(), in: context)
            strokePath(streamPath(), in: context)
            strokePath(driveOutlinePath(), in: context)
            fillCircle(center: CGPoint(x: 7.6, y: 16), radius: 1, in: context)
            fillCircle(center: CGPoint(x: 11.0, y: 16), radius: 1, in: context)
            fillCircle(center: CGPoint(x: 14.4, y: 16), radius: 1, in: context)

        case .mounted:
            // A-2-mounted.svg: open cloud, S-stream, solid drive with even-odd cut-out slot & LED.
            strokePath(openCloudPath(), in: context)
            strokePath(streamPath(), in: context)
            context.addPath(solidMountedDrivePath())
            context.fillPath(using: .evenOdd)

        case .attention:
            // A-3-needs-attention.svg: closed cloud + outlined drive + slot with a 1.1 pt clear
            // ring cut out around the solid exclamation badge at (17, 16.6) r=4.
            context.saveGState()
            let maskClip = CGMutablePath()
            maskClip.addRect(CGRect(origin: .zero, size: artboardSize))
            maskClip.addEllipse(in: CGRect(x: 17 - 5.1, y: 16.6 - 5.1, width: 10.2, height: 10.2))
            context.addPath(maskClip)
            context.clip(using: .evenOdd)
            strokePath(closedCloudPath(), in: context)
            strokePath(driveOutlinePath(), in: context)
            strokePath(driveSlotLinePath(), in: context)
            context.restoreGState()

            context.addPath(attentionBadgePath())
            context.fillPath(using: .evenOdd)
        }
    }

    // MARK: - Vector paths (exact SVG geometry from states/A-*.svg)

    private static func closedCloudPath() -> CGPath {
        // M15 10.2 H6.9 A2.2 2.2 0 1 1 7.4 5.9 A3.3 3.3 0 1 1 13.9 5.45 A2.5 2.5 0 1 1 15 10.2 Z
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 15.0, y: 10.2))
        path.addLine(to: CGPoint(x: 6.9, y: 10.2))
        addCircularSVGArc(to: path, radius: 2.2, largeArc: true, sweep: true, end: CGPoint(x: 7.4, y: 5.9))
        addCircularSVGArc(to: path, radius: 3.3, largeArc: true, sweep: true, end: CGPoint(x: 13.9, y: 5.45))
        addCircularSVGArc(to: path, radius: 2.5, largeArc: true, sweep: true, end: CGPoint(x: 15.0, y: 10.2))
        path.closeSubpath()
        return path
    }

    private static func openCloudPath() -> CGPath {
        // M9.5 10.2 H6.9 A2.2 2.2 0 1 1 7.4 5.9 A3.3 3.3 0 1 1 13.9 5.45 A2.5 2.5 0 1 1 15 10.2 H12.6
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 9.5, y: 10.2))
        path.addLine(to: CGPoint(x: 6.9, y: 10.2))
        addCircularSVGArc(to: path, radius: 2.2, largeArc: true, sweep: true, end: CGPoint(x: 7.4, y: 5.9))
        addCircularSVGArc(to: path, radius: 3.3, largeArc: true, sweep: true, end: CGPoint(x: 13.9, y: 5.45))
        addCircularSVGArc(to: path, radius: 2.5, largeArc: true, sweep: true, end: CGPoint(x: 15.0, y: 10.2))
        path.addLine(to: CGPoint(x: 12.6, y: 10.2))
        return path
    }

    private static func streamPath() -> CGPath {
        // M12.3 6.5 C10.6 6.6 10.1 8.4 11.1 9.5 S11.9 12 10.9 13
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 12.3, y: 6.5))
        path.addCurve(
            to: CGPoint(x: 11.1, y: 9.5),
            control1: CGPoint(x: 10.6, y: 6.6),
            control2: CGPoint(x: 10.1, y: 8.4)
        )
        // Smooth cubic reflection of (10.1, 8.4) across (11.1, 9.5) -> (12.1, 10.6).
        path.addCurve(
            to: CGPoint(x: 10.9, y: 13.0),
            control1: CGPoint(x: 12.1, y: 10.6),
            control2: CGPoint(x: 11.9, y: 12.0)
        )
        return path
    }

    private static func driveOutlinePath() -> CGPath {
        // <rect x="3.25" y="13" width="15.5" height="6" rx="2"/>
        CGPath(roundedRect: CGRect(x: 3.25, y: 13.0, width: 15.5, height: 6.0), cornerWidth: 2.0, cornerHeight: 2.0, transform: nil)
    }

    private static func driveSlotLinePath() -> CGPath {
        // M6.3 16 H10.6
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 6.3, y: 16.0))
        path.addLine(to: CGPoint(x: 10.6, y: 16.0))
        return path
    }

    private static func solidMountedDrivePath() -> CGPath {
        // Outer solid drive (x 2.5..19.5, y 12.25..19.75, r 2.75) minus slot capsule & LED circle.
        let path = CGMutablePath()
        path.addRoundedRect(
            in: CGRect(x: 2.5, y: 12.25, width: 17.0, height: 7.5),
            cornerWidth: 2.75,
            cornerHeight: 2.75
        )
        // Slot cut-out: M6.3 15.25 A.75 .75 0 0 0 6.3 16.75 H10.6 A.75 .75 0 0 0 10.6 15.25 Z
        path.addRoundedRect(
            in: CGRect(x: 5.55, y: 15.25, width: 5.8, height: 1.5),
            cornerWidth: 0.75,
            cornerHeight: 0.75
        )
        // LED cut-out: circle(15.4, 16, r=1)
        path.addEllipse(in: CGRect(x: 14.4, y: 15.0, width: 2.0, height: 2.0))
        return path
    }

    private static func attentionBadgePath() -> CGPath {
        // Circle (17, 16.6, r=4) minus exclamation stem capsule & dot, filled even-odd.
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: 13.0, y: 12.6, width: 8.0, height: 8.0))
        // Stem: M16.25 14.3 V16.9 A.75 .75 0 0 0 17.75 16.9 V14.3 A.75 .75 0 0 0 16.25 14.3 Z
        path.addRoundedRect(
            in: CGRect(x: 16.25, y: 13.55, width: 1.5, height: 4.1),
            cornerWidth: 0.75,
            cornerHeight: 0.75
        )
        // Dot: circle(17, 18.75, r=0.85)
        path.addEllipse(in: CGRect(x: 16.15, y: 17.9, width: 1.7, height: 1.7))
        return path
    }

    private static func strokePath(_ path: CGPath, in context: CGContext) {
        context.addPath(path)
        context.strokePath()
    }

    private static func fillCircle(center: CGPoint, radius: CGFloat, in context: CGContext) {
        context.fillEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

    /// W3C SVG 1.1 §F.6.5 endpoint-to-center conversion for circular arcs (`rx == ry`).
    private static func addCircularSVGArc(
        to path: CGMutablePath,
        radius rawRadius: CGFloat,
        largeArc: Bool,
        sweep: Bool,
        end: CGPoint
    ) {
        let start = path.currentPoint
        guard start != end, rawRadius > 0 else {
            path.addLine(to: end)
            return
        }
        let x1p = (start.x - end.x) / 2
        let y1p = (start.y - end.y) / 2
        let d2 = x1p * x1p + y1p * y1p
        let radius = max(rawRadius, sqrt(d2))
        let sq = max(0, (radius * radius - d2) / d2)
        let sign: CGFloat = (largeArc == sweep) ? -1 : 1
        let coef = sign * sqrt(sq)
        let cx = coef * y1p + (start.x + end.x) / 2
        let cy = coef * (-x1p) + (start.y + end.y) / 2
        let startAngle = atan2(start.y - cy, start.x - cx)
        let endAngle = atan2(end.y - cy, end.x - cx)
        // In CGPath coordinates, `clockwise: false` sweeps in increasing angle,
        // which is visually clockwise in a flipped (SVG y-down) context (sweep == true).
        path.addArc(
            center: CGPoint(x: cx, y: cy),
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: !sweep
        )
    }
}

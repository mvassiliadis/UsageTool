import SwiftUI

/// Geometry shared by the popover's outline and the panel that positions it under a menu-bar item.
enum PopoverChrome {
    static let caretWidth: CGFloat = 26
    static let caretHeight: CGFloat = 9
    static let cornerRadius: CGFloat = 16

    /// Distance between the menu bar's bottom edge and the caret's tip.
    static let menuBarGap: CGFloat = 4

    /// Smallest distance the panel keeps from the edges of the screen it is shown on.
    static let screenMargin: CGFloat = 8

    /// How far the caret's tip may sit from the panel's own horizontal centre before the panel
    /// would have to overlap a corner. Used to clamp the tip on a menu-bar item near a screen edge.
    static var caretInset: CGFloat { cornerRadius + caretWidth / 2 }
}

/// The popover's outline: a rounded panel with a caret on top pointing at its menu-bar item.
///
/// One continuous path rather than a rectangle plus a triangle, so the stroke runs along the
/// caret's sides and the window shadow follows the whole silhouette.
struct PopoverChromeShape: Shape {
    /// The caret tip's x position, in the shape's own coordinate space.
    var caretX: CGFloat

    var animatableData: CGFloat {
        get { caretX }
        set { caretX = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = PopoverChrome.cornerRadius
        let half = PopoverChrome.caretWidth / 2
        // The panel body starts below the caret; the caret occupies the top strip of `rect`.
        let shoulderY = rect.minY + PopoverChrome.caretHeight
        let tipX = min(max(caretX, rect.minX + PopoverChrome.caretInset), rect.maxX - PopoverChrome.caretInset)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: shoulderY))
        path.addLine(to: CGPoint(x: tipX - half, y: shoulderY))
        // Control points level with the tip keep the caret's sides nearly straight while rounding
        // its apex; a sharp point reads as an artifact next to the panel's rounded corners.
        path.addQuadCurve(to: CGPoint(x: tipX, y: rect.minY), control: CGPoint(x: tipX - half * 0.3, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: tipX + half, y: shoulderY), control: CGPoint(x: tipX + half * 0.3, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: shoulderY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: shoulderY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: shoulderY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: shoulderY), tangent2End: CGPoint(x: rect.maxX, y: shoulderY), radius: radius)
        path.closeSubpath()
        return path
    }
}

/// Wraps the popover in its own background so it can be shown in a transparent panel.
struct PopoverChromeContainer<Content: View>: View {
    /// The caret tip's x position, measured from the container's leading edge.
    var caretX: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        let shape = PopoverChromeShape(caretX: caretX)
        content
            .padding(.top, PopoverChrome.caretHeight)
            .background {
                shape
                    .fill(.regularMaterial)
                    .overlay { shape.stroke(Color.primary.opacity(0.12), lineWidth: 1) }
            }
            // The panel is transparent, so everything must be composited together before the
            // window derives its shadow from the result.
            .compositingGroup()
    }
}

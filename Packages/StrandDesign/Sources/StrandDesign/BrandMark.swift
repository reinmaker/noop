import SwiftUI

// MARK: - BrandMark — the NOOP logo mark (Titanium & Gold)
//
// The app's identity glyph, rendered natively for use as a hero on onboarding,
// "about", and empty states. Per the design handoff ("Engraved" app-icon
// direction + the brand glyph spec):
//
//   • a circular DEEP-NAVY tile (Circle filled with the navy ramp, a faint top
//     sheen, and a 1px hairline rim), over which sits
//   • an OPEN GOLD recovery ring — an ~80% arc starting at 12 o'clock (-90°) and
//     sweeping clockwise, stroked with the gold ramp and round-capped (a THICK
//     stroke to match the app icon), and
//   • a solid GOLD CORE DOT centred ("on-device core").
//
// Gold-on-navy, matching the app icon (the maintainer's brand direction, 2026-06-15).
//
// It reads as the "O" in NOOP and as a small echo of the hero recovery ring.
// CLEAN and flat by design: no bloom, no shadow, no glow — the titanium does the
// depth via its gradient + sheen, the gold ring does the accent. Everything is
// driven off a single `size`, so the mark stays crisp from a 28pt list avatar up
// to a 120pt onboarding hero.

public struct BrandMark: View {

    /// Edge length of the square mark; everything scales from this.
    public var size: CGFloat

    public init(size: CGFloat = 120) {
        self.size = size
    }

    // The open ring sweeps ~80% of a full turn (≈291° of 364, per the logo spec),
    // starting at 12 o'clock and going clockwise — the same orientation as the
    // hero recovery ring, so the two read as one family.
    private let openFraction: Double = 0.80
    private var startAngle: Angle { .degrees(-90) }

    // Proportions derived from `size` so the mark is resolution-independent.
    private var ringInset: CGFloat { size * 0.20 }          // tile edge → ring band
    private var ringWidth: CGFloat { size * 0.13 }          // THICK gold stroke (matches the icon)
    private var ringDiameter: CGFloat { size - ringInset * 2 }
    private var coreDiameter: CGFloat { size * 0.18 }       // centre core dot
    private var rimWidth: CGFloat { max(1, size * 0.008) }  // ~1px hairline rim

    public var body: some View {
        // Yoop: the app icon's mark (a three-part score ring around a white Y) on the dark disc. The NOOP
        // ring + core below stay in the file for reference but are no longer drawn.
        ZStack {
            yoopTile
            yoopRing
            YoopYShape()
                .stroke(Color(hex: "#FFFFFF"),
                        style: StrokeStyle(lineWidth: size * 74 / 1024, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Yoop"))
        .accessibilityAddTraits(.isImage)
    }

    // MARK: Yoop mark (matches Tools/yoop-icon/yoop.svg)

    private var yoopTile: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(hex: "#232B33"), Color(hex: "#0B0E11")],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(StrandPalette.hairline, lineWidth: rimWidth))
    }

    /// Sleep (blue-grey), Recovery (green) and Strain (blue) arcs, 104 degrees each, as in the icon.
    private var yoopRing: some View {
        let arcs: [(start: Double, color: Color)] = [
            (8, Color(hex: "#16D9A0")), (128, Color(hex: "#0093E7")), (248, Color(hex: "#7BA1BB")),
        ]
        return ZStack {
            ForEach(arcs.indices, id: \.self) { i in
                Circle()
                    .trim(from: arcs[i].start / 360, to: (arcs[i].start + 104) / 360)
                    .stroke(arcs[i].color, style: StrokeStyle(lineWidth: size * 66 / 1024, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size * 636 / 1024, height: size * 636 / 1024)
    }

    // MARK: Deep-navy tile

    /// The navy disc the gold mark sits on — a deep-navy vertical ramp (lifted at
    /// the top, deeper at the bottom) with a faint cool top sheen and a soft
    /// hairline rim, matching the app icon. No shadow — flat and clean.
    private var navyTile: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color(hex: "#1A1E24"), Color(hex: "#0E1116")],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            // Faint cool top sheen — a soft light catch across the upper third (flat, no bloom).
            .overlay(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#2A2F37").opacity(0.5), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .opacity(0.6)
            )
            // 1px hairline rim so the disc reads cleanly on the navy canvas.
            .overlay(
                Circle().strokeBorder(StrandPalette.hairline, lineWidth: rimWidth)
            )
    }

    // MARK: Open gold recovery ring

    /// The open ~80% gold arc — round-capped, stroked with the gold ramp via an
    /// AngularGradient so the metal shifts along the sweep (light → gold → deep),
    /// matching how the hero recovery ring fills.
    private var goldRing: some View {
        RecoveryArc(
            startAngle: startAngle,
            spanDegrees: 360 * openFraction,
            fraction: 1,
            lineWidth: ringWidth
        )
        .stroke(
            StrandPalette.chargeColor,
            style: StrokeStyle(lineWidth: ringWidth, lineCap: .round)
        )
        .frame(width: ringDiameter, height: ringDiameter)
    }

    // MARK: Solid gold core

    /// The "on-device core" — a solid gold dot at the exact centre, completing the
    /// open-ring + core-dot lock-up.
    private var coreDot: some View {
        Circle()
            .fill(Color.white)
            .frame(width: coreDiameter, height: coreDiameter)
    }
}

#if DEBUG
#Preview("BrandMark — sizes") {
    VStack(spacing: 40) {
        BrandMark(size: 120)
        HStack(spacing: 28) {
            BrandMark(size: 72)
            BrandMark(size: 44)
            BrandMark(size: 28)
        }
    }
    .padding(48)
    .frame(width: 420, height: 460)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif


/// The Y of the Yoop mark, in the icon's 1024-unit coordinates scaled to the frame.
struct YoopYShape: Shape {
    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 1024
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        var path = Path()
        path.move(to: p(418, 382))
        path.addLine(to: p(512, 500))
        path.addLine(to: p(606, 382))
        path.move(to: p(512, 500))
        path.addLine(to: p(512, 648))
        return path
    }
}

import SwiftUI

/// Classic 3.5" / 5.25" floppy face used as the mounted-disc badge.
struct FloppyVisual: View {
    let media: DisketteEngine.Media
    let label: String
    let fillFraction: Double
    var compact: Bool = false

    private var isThreeHalf: Bool { media.formFactor == .threeHalf }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                if isThreeHalf {
                    threeHalfBody(size: s)
                } else {
                    fiveQuarterBody(size: s)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(isThreeHalf ? 1.0 : 1.05, contentMode: .fit)
        .accessibilityLabel("\(label), \(media.displayName), \(Int(fillFraction * 100)) percent full")
    }

    // MARK: - 3.5"

    private func threeHalfBody(size: CGFloat) -> some View {
        let shell = RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
        return ZStack {
            // Plastic shell
            shell
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.20, blue: 0.28),
                            Color(red: 0.10, green: 0.11, blue: 0.16),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.35), radius: size * 0.04, y: size * 0.02)

            shell
                .strokeBorder(Color.white.opacity(0.12), lineWidth: max(1, size * 0.008))

            // Metal shutter
            RoundedRectangle(cornerRadius: size * 0.02, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(white: 0.72),
                            Color(white: 0.48),
                            Color(white: 0.62),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: size * 0.42, height: size * 0.22)
                .offset(y: -size * 0.32)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.02)
                        .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                        .frame(width: size * 0.42, height: size * 0.22)
                        .offset(y: -size * 0.32)
                )

            // Write-protect notch (right)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black.opacity(0.45))
                .frame(width: size * 0.06, height: size * 0.08)
                .offset(x: size * 0.38, y: -size * 0.28)

            // Hub ring
            Circle()
                .fill(Color(white: 0.35))
                .frame(width: size * 0.22, height: size * 0.22)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .overlay(
                    Circle()
                        .fill(Color(white: 0.15))
                        .frame(width: size * 0.08, height: size * 0.08)
                )
                .offset(y: size * 0.02)

            // Label area
            VStack(spacing: size * 0.02) {
                Spacer()
                RoundedRectangle(cornerRadius: size * 0.02, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.95, green: 0.94, blue: 0.88),
                                Color(red: 0.88, green: 0.86, blue: 0.78),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: size * 0.28)
                    .padding(.horizontal, size * 0.1)
                    .overlay(
                        VStack(spacing: 2) {
                            Text(label.isEmpty ? "Untitled" : label)
                                .font(.system(size: max(9, size * 0.065), weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.15, green: 0.15, blue: 0.2))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            Text(media.shortName)
                                .font(.system(size: max(8, size * 0.045), weight: .medium, design: .monospaced))
                                .foregroundStyle(Color(red: 0.4, green: 0.38, blue: 0.32))
                            // Capacity bar on label
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.black.opacity(0.08))
                                    Capsule()
                                        .fill(fillColor)
                                        .frame(width: max(2, g.size.width * CGFloat(min(1, fillFraction))))
                                }
                            }
                            .frame(height: max(3, size * 0.02))
                            .padding(.horizontal, size * 0.06)
                        }
                        .padding(.horizontal, size * 0.12)
                        .padding(.vertical, size * 0.03)
                    )
                    .padding(.bottom, size * 0.08)
            }
        }
        .padding(compact ? 4 : 8)
    }

    // MARK: - 5.25"

    private func fiveQuarterBody(size: CGFloat) -> some View {
        let shell = RoundedRectangle(cornerRadius: size * 0.03, style: .continuous)
        return ZStack {
            shell
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.22, green: 0.18, blue: 0.14),
                            Color(red: 0.12, green: 0.10, blue: 0.08),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.35), radius: size * 0.04, y: size * 0.02)

            shell
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)

            // Center hub hole
            Circle()
                .fill(Color.black.opacity(0.55))
                .frame(width: size * 0.18, height: size * 0.18)

            // Index hole
            Circle()
                .fill(Color.black.opacity(0.45))
                .frame(width: size * 0.035, height: size * 0.035)
                .offset(x: size * 0.18, y: -size * 0.02)

            // Head window (oval cutout)
            Capsule()
                .fill(Color.black.opacity(0.5))
                .frame(width: size * 0.14, height: size * 0.38)
                .offset(y: size * 0.08)

            // Label strip at top
            VStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.92, green: 0.90, blue: 0.82))
                    .frame(height: size * 0.2)
                    .padding(.horizontal, size * 0.08)
                    .overlay(
                        VStack(spacing: 2) {
                            Text(label.isEmpty ? "Untitled" : label)
                                .font(.system(size: max(9, size * 0.055), weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.15, green: 0.12, blue: 0.1))
                                .lineLimit(1)
                            Text(media.shortName)
                                .font(.system(size: max(8, size * 0.04), weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    )
                    .padding(.top, size * 0.06)
                Spacer()
            }

            // Capacity arc
            Circle()
                .trim(from: 0, to: CGFloat(min(1, fillFraction)))
                .stroke(fillColor, style: StrokeStyle(lineWidth: max(2, size * 0.02), lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: size * 0.55, height: size * 0.55)
                .opacity(0.85)
        }
        .padding(compact ? 4 : 8)
    }

    private var fillColor: Color {
        if fillFraction >= 0.95 { return Color(red: 0.85, green: 0.25, blue: 0.22) }
        if fillFraction >= 0.75 { return Color(red: 0.9, green: 0.55, blue: 0.15) }
        return Color(red: 0.25, green: 0.55, blue: 0.85)
    }
}

struct CapacityMeter: View {
    let used: Int
    let capacity: Int

    private var fraction: Double {
        guard capacity > 0 else { return 0 }
        return min(1, Double(used) / Double(capacity))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(4, g.size.width * CGFloat(fraction)))
                }
            }
            .frame(height: 8)
            HStack {
                Text("\(DisketteEngine.formatBytes(used)) used")
                Spacer()
                Text("\(DisketteEngine.formatBytes(capacity - used)) free · \(DisketteEngine.formatBytes(capacity))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var barColor: Color {
        if fraction >= 0.95 { return Color(red: 0.85, green: 0.25, blue: 0.22) }
        if fraction >= 0.75 { return Color(red: 0.9, green: 0.55, blue: 0.15) }
        return AppTheme.accent
    }
}

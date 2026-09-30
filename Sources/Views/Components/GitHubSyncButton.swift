import SwiftUI

public struct GitHubSyncButton: View {
    @ObservedObject var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 5) {
            // 1. Pull Button
            LiquidGlassSyncButton(
                iconName: "arrow.down",
                label: "Pull",
                loadingLabel: "Pulling",
                isLoading: state.isPulling,
                count: state.commitsBehind,
                hasActionWeight: state.commitsBehind > 0,
                accentColor: state.accentTheme.primaryColor,
                helpText: state.commitsBehind > 0 ? "Pull \(state.commitsBehind) commits from origin" : "Pull latest changes from origin"
            ) {
                state.pullOrigin()
            } secondaryAction: {
                state.pullOrigin()
            }

            // 2. Push Button
            LiquidGlassSyncButton(
                iconName: "arrow.up",
                label: "Push",
                loadingLabel: "Pushing",
                isLoading: state.isPushing,
                count: state.commitsAhead,
                hasActionWeight: state.commitsAhead > 0,
                accentColor: state.accentTheme.primaryColor,
                helpText: state.commitsAhead > 0 ? "Push \(state.commitsAhead) commits to origin" : "Push commits to origin"
            ) {
                state.pushOrigin()
            } secondaryAction: {
                state.forcePushOrigin()
            }

            // 3. Fetch Button
            LiquidGlassSyncButton(
                iconName: "arrow.triangle.2.circlepath",
                label: "Fetch",
                loadingLabel: "Fetching",
                isLoading: state.isFetching,
                count: 0,
                hasActionWeight: false,
                accentColor: state.accentTheme.primaryColor,
                helpText: "Fetch origin (\(state.lastFetchedText))"
            ) {
                state.fetchOrigin()
            } secondaryAction: {
                state.fetchOrigin()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Liquid Glass Sync Button Component

private struct LiquidGlassSyncButton: View {
    let iconName: String
    let label: String
    let loadingLabel: String
    let isLoading: Bool
    let count: Int
    let hasActionWeight: Bool
    let accentColor: Color
    let helpText: String
    let action: () -> Void
    let secondaryAction: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: {
            guard !isLoading else { return }
            action()
        }) {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isLoading)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let cycleDuration: Double = 1.35
                let phase = CGFloat(time.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration)

                HStack(spacing: 4.5) {
                    // Icon with fixed container & subtle motion during loading
                    Image(systemName: iconName)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .foregroundStyle(
                            isLoading || hasActionWeight
                                ? accentColor
                                : (isHovered ? Color.white : Color.primary.opacity(0.85))
                        )
                        .rotationEffect(.degrees((isLoading && iconName.contains("circle")) ? time * 320 : 0))
                        .offset(
                            y: isLoading
                                ? (iconName == "arrow.down" ? sin(time * 8) * 1.8 : (iconName == "arrow.up" ? -sin(time * 8) * 1.8 : 0))
                                : 0
                        )

                    // Text label container with permanent fixed-width reservation for "ING" form (zero layout shift)
                    ZStack(alignment: .leading) {
                        // Invisible sizing anchor locks the width to the longer "ING" string
                        Text(loadingLabel)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .opacity(0)

                        // Visible text swaps without shifting button dimensions or neighbors
                        Text(isLoading ? loadingLabel : label)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(
                                isLoading
                                    ? Color.white
                                    : (isHovered ? Color.white : Color.primary.opacity(0.85))
                            )
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    // Count badge: stays visible during sync so badge removal doesn't shift layout
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundStyle(hasActionWeight ? accentColor : Color.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                hasActionWeight
                                    ? accentColor.opacity(0.20)
                                    : Color.white.opacity(0.10)
                            )
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        hasActionWeight ? accentColor.opacity(0.35) : Color.white.opacity(0.15),
                                        lineWidth: 0.5
                                    )
                            )
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .fixedSize(horizontal: true, vertical: false)
                .background(
                    backgroundFill(phase: phase)
                )
                .overlay(
                    specularBorder
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .shadow(
                    color: isLoading
                        ? accentColor.opacity(0.30)
                        : Color.black.opacity(0.22),
                    radius: isLoading ? 3.5 : 2.5,
                    x: 0,
                    y: 1.5
                )
                .scaleEffect(isHovered && !isLoading ? 1.02 : 1.0)
                .animation(.easeInOut(duration: 0.12), value: isHovered)
            }
        }
        .buttonStyle(.hoverPlain)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovered = $0 }
        .help(helpText)
        .contextMenu {
            if label == "Push" {
                Button("Push to origin") { action() }
                Button("Force Push (with lease)") { secondaryAction() }
            } else if label == "Pull" {
                Button("Pull from origin") { action() }
            } else if label == "Fetch" {
                Button("Fetch origin") { action() }
            }
        }
    }

    // MARK: - Background Fill with Smooth Liquid-Glass Shimmer

    @ViewBuilder
    private func backgroundFill(phase: CGFloat) -> some View {
        if isLoading {
            ZStack {
                // 1. Stable tinted translucent glass base (no flicker or jumps)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(accentColor.opacity(0.14))

                // 2. Continuous feathered gradient wash sweeping left-to-right (no solid edges/polygons)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: accentColor.opacity(0.08), location: 0.22),
                        .init(color: accentColor.opacity(0.28), location: 0.42),
                        .init(color: Color.white.opacity(0.40), location: 0.50),
                        .init(color: accentColor.opacity(0.28), location: 0.58),
                        .init(color: accentColor.opacity(0.08), location: 0.78),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: UnitPoint(x: -1.2 + phase * 2.8, y: -0.2),
                    endPoint: UnitPoint(x: -0.2 + phase * 2.8, y: 1.2)
                )

                // 3. Top-half specular gloss matching resting glass aesthetic
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.22),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 14)
                    Spacer()
                }
                .padding(1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            ZStack {
                // Translucent glass base with subtle action tint when weighted
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        hasActionWeight
                            ? accentColor.opacity(isHovered ? 0.16 : 0.08)
                            : (isHovered ? Color.white.opacity(0.14) : Color.white.opacity(0.06))
                    )

                // Top-half specular gloss
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isHovered ? 0.28 : 0.12),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 14)
                    Spacer()
                }
                .padding(1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    // MARK: - Specular Border

    private var specularBorder: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        isLoading
                            ? accentColor.opacity(0.65)
                            : (hasActionWeight
                                ? accentColor.opacity(isHovered ? 0.55 : 0.30)
                                : Color.white.opacity(isHovered ? 0.45 : 0.22)),
                        isLoading
                            ? accentColor.opacity(0.25)
                            : (hasActionWeight
                                ? accentColor.opacity(isHovered ? 0.20 : 0.10)
                                : Color.white.opacity(isHovered ? 0.14 : 0.05))
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 1
            )
    }
}

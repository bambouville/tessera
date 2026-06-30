import SwiftUI

struct TesseraLogo: View {
    var size: CGFloat = 16
    var color: Color? = nil

    @Environment(\.designTokens) private var T

    var body: some View {
        let scale = size / Self.viewBoxSize

        ZStack {
            Path { path in
                path.addRoundedRect(
                    in: CGRect(
                        x: 22 * scale,
                        y: 22 * scale,
                        width: 96 * scale,
                        height: 96 * scale
                    ),
                    cornerSize: CGSize(width: 22 * scale, height: 22 * scale),
                    style: .continuous
                )
            }
            .fill(color ?? T.fg)

            Path { path in
                path.addRoundedRect(
                    in: CGRect(
                        x: 34 * scale,
                        y: 34 * scale,
                        width: 26 * scale,
                        height: 26 * scale
                    ),
                    cornerSize: CGSize(width: 5 * scale, height: 5 * scale),
                    style: .continuous
                )
            }
            .fill(T.accent)
        }
        .frame(width: size, height: size)
    }

    private static let viewBoxSize: CGFloat = 140
}

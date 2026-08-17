import SwiftUI

/// A compact cat paw drawn without an SF Symbol. The four toe pads are small,
/// round, and close together; the palm pad is wider than it is tall. Those
/// proportions remain recognizable at the Widget's 18–20 point icon size.
struct CatPawMark: View {
    var isFilled: Bool

    var body: some View {
        ZStack {
            if isFilled {
                CatPawShape()
                    .fill(.foreground)
            } else {
                CatPawShape()
                    .stroke(
                        .foreground,
                        style: StrokeStyle(
                            lineWidth: 1.45,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct CatPawShape: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: rect.minX + rect.width * x / 20,
                y: rect.minY + rect.height * y / 20
            )
        }

        func ellipse(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(
                x: rect.minX + rect.width * x / 20,
                y: rect.minY + rect.height * y / 20,
                width: rect.width * width / 20,
                height: rect.height * height / 20
            )
        }

        var path = Path()
        path.addEllipse(in: ellipse(3.50, 5.20, 2.80, 3.20))
        path.addEllipse(in: ellipse(6.80, 3.10, 2.80, 3.25))
        path.addEllipse(in: ellipse(10.40, 3.10, 2.80, 3.25))
        path.addEllipse(in: ellipse(13.70, 5.20, 2.80, 3.20))

        var palm = Path()
        palm.move(to: point(10, 8.20))
        palm.addCurve(
            to: point(4.20, 13.00),
            control1: point(7.20, 7.90),
            control2: point(4.50, 10.20)
        )
        palm.addCurve(
            to: point(8.20, 16.00),
            control1: point(3.80, 15.70),
            control2: point(5.80, 16.90)
        )
        palm.addCurve(
            to: point(10, 15.20),
            control1: point(9.00, 15.70),
            control2: point(9.40, 15.20)
        )
        palm.addCurve(
            to: point(11.80, 16.00),
            control1: point(10.60, 15.20),
            control2: point(11.00, 15.70)
        )
        palm.addCurve(
            to: point(15.80, 13.00),
            control1: point(14.20, 16.90),
            control2: point(16.20, 15.70)
        )
        palm.addCurve(
            to: point(10, 8.20),
            control1: point(15.50, 10.20),
            control2: point(12.80, 7.90)
        )
        palm.closeSubpath()
        path.addPath(palm)
        return path
    }
}

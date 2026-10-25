import SwiftUI
import UIKit

/// Pinch and drag a photo to choose the part that's used (circle for profile photos, square for covers).
struct ImageCropper: View {
    let image: UIImage
    var circle = true
    var onDone: (UIImage) -> Void
    var onCancel: () -> Void

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag: CGSize = .zero

    private let maxScale: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) - 40
            let base = baseSize(side)
            let liveScale = min(max(scale * pinch, 1), maxScale)
            let liveOffset = clamped(CGSize(width: offset.width + drag.width, height: offset.height + drag.height),
                                     scale: liveScale, base: base, side: side)
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .frame(width: base.width * liveScale, height: base.height * liveScale)
                    .offset(liveOffset)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                // Darken everything outside the crop area.
                Rectangle()
                    .fill(.black.opacity(0.6))
                    .mask {
                        ZStack {
                            Rectangle()
                            cropShape(side).blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                    .allowsHitTesting(false)
                cropOutline(side).allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    MagnifyGesture().updating($pinch) { v, s, _ in s = v.magnification }
                        .onEnded { v in
                            scale = min(max(scale * v.magnification, 1), maxScale)
                            offset = clamped(offset, scale: scale, base: base, side: side)
                        },
                    DragGesture().updating($drag) { v, s, _ in s = v.translation }
                        .onEnded { v in
                            offset = clamped(CGSize(width: offset.width + v.translation.width,
                                                    height: offset.height + v.translation.height),
                                             scale: scale, base: base, side: side)
                        }
                )
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) {
                    scale = scale > 1 ? 1 : 2
                    offset = clamped(offset, scale: scale, base: base, side: side)
                }
            }
            .overlay(alignment: .top) {
                HStack {
                    Button("Cancel", action: onCancel)
                        .frame(minWidth: 44, minHeight: 44)
                    Spacer()
                    Text("Move and scale").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Choose") { onDone(render(side: side, base: base)) }
                        .fontWeight(.bold)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
    }

    @ViewBuilder private func cropShape(_ side: CGFloat) -> some View {
        if circle {
            Circle().frame(width: side, height: side)
        } else {
            Rectangle().frame(width: side, height: side)
        }
    }

    @ViewBuilder private func cropOutline(_ side: CGFloat) -> some View {
        if circle {
            Circle().stroke(.white.opacity(0.8), lineWidth: 1).frame(width: side, height: side)
        } else {
            Rectangle().stroke(.white.opacity(0.8), lineWidth: 1).frame(width: side, height: side)
        }
    }

    /// Size of the photo at zoom 1: just big enough to fill the crop area.
    private func baseSize(_ side: CGFloat) -> CGSize {
        let w = max(image.size.width, 1), h = max(image.size.height, 1)
        let fill = side / min(w, h)
        return CGSize(width: w * fill, height: h * fill)
    }

    /// Keeps the photo covering the whole crop area.
    private func clamped(_ o: CGSize, scale: CGFloat, base: CGSize, side: CGFloat) -> CGSize {
        let maxX = max((base.width * scale - side) / 2, 0)
        let maxY = max((base.height * scale - side) / 2, 0)
        return CGSize(width: min(max(o.width, -maxX), maxX), height: min(max(o.height, -maxY), maxY))
    }

    /// The chosen part as a square image (600×600).
    private func render(side: CGFloat, base: CGSize) -> UIImage {
        let s = min(max(scale, 1), maxScale)
        let o = clamped(offset, scale: s, base: base, side: side)
        let shown = CGSize(width: base.width * s, height: base.height * s)
        // Crop square in the coordinates of the shown photo.
        let x = (shown.width - side) / 2 - o.width
        let y = (shown.height - side) / 2 - o.height
        let out: CGFloat = 600
        let k = out / side
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: out, height: out), format: format).image { _ in
            image.draw(in: CGRect(x: -x * k, y: -y * k, width: shown.width * k, height: shown.height * k))
        }
    }
}

/// A picked photo waiting to be cropped.
struct CropRequest: Identifiable {
    let id = UUID()
    let image: UIImage
}

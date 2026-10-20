import CoreGraphics
import ScanDeckCore
import SwiftUI

struct ManualCropEditorRequest: Identifiable, Equatable {
    let cardID: CardID
    let cardNumber: UInt64
    let side: OutputSide
    let scan: ScanSideViewData

    var id: MasterID { scan.id }
}

struct ManualCropEditorView: View {
    let request: ManualCropEditorRequest
    let apply: (ManualCropRect) -> Void
    let reset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preview: CGImage?
    @State private var selection: ManualCropRect?
    @State private var dragStart: CGPoint?

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 5) {
                Text("Crop Card \(SheetNumber.formatted(request.cardNumber)) \(request.side.title)")
                    .font(.title2.weight(.semibold))
                Text("Drag from one corner of the physical card to the opposite corner.")
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                if let preview {
                    let imageRect = fittedRect(
                        imageSize: CGSize(width: preview.width, height: preview.height),
                        in: proxy.size
                    )

                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(0.92)

                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: imageRect.midX, y: imageRect.midY)

                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: imageRect.width, height: imageRect.height)
                            .position(x: imageRect.midX, y: imageRect.midY)
                            .gesture(selectionGesture(in: imageRect))
                            .accessibilityLabel("Scanned image crop area")
                            .accessibilityHint("Drag across the image to select the physical card edge")

                        if let selection {
                            let rect = displayRect(for: selection, in: imageRect)
                            Rectangle()
                                .fill(Color.black.opacity(0.42))
                                .mask {
                                    Rectangle()
                                        .overlay {
                                            Rectangle()
                                                .frame(width: rect.width, height: rect.height)
                                                .position(x: rect.midX, y: rect.midY)
                                                .blendMode(.destinationOut)
                                        }
                                        .compositingGroup()
                                }
                                .allowsHitTesting(false)

                            Rectangle()
                                .stroke(Color.accentColor, lineWidth: 3)
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .allowsHitTesting(false)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .coordinateSpace(name: "manualCropCanvas")
                } else {
                    ContentUnavailableView(
                        "Preview Unavailable",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("The original scan could not be loaded.")
                    )
                }
            }
            .frame(minHeight: 500)

            HStack {
                if request.scan.manualCrop != nil {
                    Button("Reset to Automatic", systemImage: "wand.and.stars") {
                        reset()
                        dismiss()
                    }
                }

                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Apply Crop") {
                    guard let selection else { return }
                    apply(selection)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selection?.isValid != true)
            }
        }
        .padding(22)
        .frame(minWidth: 760, minHeight: 680)
        .task(id: request.scan.imageURL) {
            selection = request.scan.manualCrop
            guard let imageURL = request.scan.imageURL else {
                preview = nil
                return
            }
            preview = await ThumbnailStore.shared.thumbnail(for: imageURL)
        }
    }

    private func selectionGesture(in imageRect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("manualCropCanvas"))
            .onChanged { value in
                let current = clamped(value.location, to: imageRect)
                let start = dragStart ?? current
                dragStart = start

                let rect = CGRect(
                    x: min(start.x, current.x),
                    y: min(start.y, current.y),
                    width: abs(current.x - start.x),
                    height: abs(current.y - start.y)
                )
                selection = normalizedRect(from: rect, in: imageRect)
            }
            .onEnded { _ in
                dragStart = nil
                if selection?.isValid != true {
                    selection = nil
                }
            }
    }

    private func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func clamped(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, rect.minX), rect.maxX),
            y: min(max(point.y, rect.minY), rect.maxY)
        )
    }

    private func normalizedRect(from rect: CGRect, in imageRect: CGRect) -> ManualCropRect? {
        guard imageRect.width > 0, imageRect.height > 0 else { return nil }
        let result = ManualCropRect(
            x: (rect.minX - imageRect.minX) / imageRect.width,
            y: (rect.minY - imageRect.minY) / imageRect.height,
            width: rect.width / imageRect.width,
            height: rect.height / imageRect.height
        )
        return result.isValid ? result : nil
    }

    private func displayRect(for crop: ManualCropRect, in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + crop.x * imageRect.width,
            y: imageRect.minY + crop.y * imageRect.height,
            width: crop.width * imageRect.width,
            height: crop.height * imageRect.height
        )
    }
}

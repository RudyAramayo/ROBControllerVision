import AVFoundation
import SwiftUI
import UIKit

struct SampleBufferVideoView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> SampleBufferVideoHostView {
        SampleBufferVideoHostView(displayLayer: displayLayer)
    }

    func updateUIView(_ view: SampleBufferVideoHostView, context: Context) {
        view.attach(displayLayer)
    }

    static func dismantleUIView(_ view: SampleBufferVideoHostView, coordinator: Void) {
        view.detach()
    }
}

@MainActor
final class SampleBufferVideoHostView: UIView {
    private weak var hostedDisplayLayer: AVSampleBufferDisplayLayer?

    init(displayLayer: AVSampleBufferDisplayLayer) {
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        attach(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func attach(_ displayLayer: AVSampleBufferDisplayLayer) {
        guard hostedDisplayLayer !== displayLayer else { return }
        hostedDisplayLayer?.removeFromSuperlayer()
        displayLayer.removeFromSuperlayer()
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
        hostedDisplayLayer = displayLayer
        setNeedsLayout()
    }

    func detach() {
        hostedDisplayLayer?.removeFromSuperlayer()
        hostedDisplayLayer = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedDisplayLayer?.frame = bounds
        CATransaction.commit()
    }
}

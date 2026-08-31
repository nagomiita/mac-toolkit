import AVFoundation
import SwiftUI

/// AVSampleBufferDisplayLayer を SwiftUI に載せるためのホスト。
struct VideoSurfaceView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
        view.hostedLayer = layer
        return view
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        uiView.hostedLayer = layer
    }

    final class HostView: UIView {
        var hostedLayer: AVSampleBufferDisplayLayer? {
            didSet {
                guard oldValue !== hostedLayer else { return }
                oldValue?.removeFromSuperlayer()
                if let hostedLayer {
                    layer.addSublayer(hostedLayer)
                }
                setNeedsLayout()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // 回転やリサイズで映像がスライドして見えないよう
            // 暗黙のアニメーションを止めて即座に追従させる。
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}

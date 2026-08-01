import CoreGraphics
import CoreVideo
import Foundation
import ROBControlCore

public final class SyntheticPixelBufferSource {
    public let width: Int
    public let height: Int
    private let pixelBufferPool: CVPixelBufferPool
    private let allocationAttributes: CFDictionary

    public init(width: Int, height: Int) throws {
        guard width > 0,
            height > 0,
            width <= VideoDataChannelLimits.hardMaximumVideoDimension,
            height <= VideoDataChannelLimits.hardMaximumVideoDimension,
            width * height <= VideoDataChannelLimits.hardMaximumDecodedPixels
        else {
            throw VideoPipelineError.invalidDimensions(width: width, height: height)
        }
        self.width = width
        self.height = height
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 4
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            attributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw VideoPipelineError.pixelBufferCreationFailed(status)
        }
        self.pixelBufferPool = pool
        self.allocationAttributes =
            [
                kCVPixelBufferPoolAllocationThresholdKey: 6
            ] as CFDictionary
    }

    public func makeFrame(sequence: UInt64) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            pixelBufferPool,
            allocationAttributes,
            &pixelBuffer
        )
        if status == kCVReturnWouldExceedAllocationThreshold {
            throw VideoPipelineError.pixelBufferPoolExhausted
        }
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw VideoPipelineError.pixelBufferCreationFailed(status)
        }

        try drawFrame(in: pixelBuffer, sequence: sequence)
        return pixelBuffer
    }

    private func drawFrame(in pixelBuffer: CVPixelBuffer, sequence: UInt64) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw VideoPipelineError.drawingContextCreationFailed
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard
            let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        else {
            throw VideoPipelineError.drawingContextCreationFailed
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 0.025, green: 0.045, blue: 0.09, alpha: 1))
        context.fill(bounds)

        drawGrid(in: context)
        drawHorizon(in: context, sequence: sequence)
        drawRobot(in: context, sequence: sequence)
        drawTelemetry(in: context, sequence: sequence)
    }

    private func drawGrid(in context: CGContext) {
        context.saveGState()
        context.setStrokeColor(CGColor(red: 0.08, green: 0.42, blue: 0.52, alpha: 0.28))
        context.setLineWidth(1)
        let spacing = max(32, width / 16)
        for x in stride(from: 0, through: width, by: spacing) {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: height))
        }
        for y in stride(from: 0, through: height, by: spacing) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: width, y: y))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawHorizon(in context: CGContext, sequence: UInt64) {
        let phase = CGFloat(sequence % 240) / 240
        let scanX = phase * CGFloat(width)

        context.saveGState()
        context.setStrokeColor(CGColor(red: 0.15, green: 0.9, blue: 0.92, alpha: 0.75))
        context.setLineWidth(3)
        context.move(to: CGPoint(x: 0, y: CGFloat(height) * 0.58))
        context.addLine(to: CGPoint(x: CGFloat(width), y: CGFloat(height) * 0.58))
        context.strokePath()

        context.setFillColor(CGColor(red: 0.1, green: 0.82, blue: 0.9, alpha: 0.18))
        context.fill(
            CGRect(x: scanX - 12, y: 0, width: 24, height: CGFloat(height))
        )
        context.restoreGState()
    }

    private func drawRobot(in context: CGContext, sequence: UInt64) {
        let angle = Double(sequence) * 0.045
        let centerX = CGFloat(width) * (0.5 + 0.23 * cos(angle))
        let centerY = CGFloat(height) * (0.47 + 0.16 * sin(angle * 0.7))
        let radius = CGFloat(min(width, height)) * 0.065

        context.saveGState()
        context.setShadow(
            offset: .zero,
            blur: radius * 0.6,
            color: CGColor(red: 0.2, green: 0.95, blue: 0.8, alpha: 0.75)
        )
        context.setFillColor(CGColor(red: 0.12, green: 0.9, blue: 0.72, alpha: 1))
        context.fillEllipse(
            in: CGRect(
                x: centerX - radius,
                y: centerY - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        context.restoreGState()

        context.setStrokeColor(CGColor(red: 0.85, green: 1, blue: 0.97, alpha: 1))
        context.setLineWidth(4)
        context.move(to: CGPoint(x: centerX, y: centerY))
        context.addLine(
            to: CGPoint(
                x: centerX + cos(angle) * radius * 1.8,
                y: centerY + sin(angle) * radius * 1.8
            )
        )
        context.strokePath()
    }

    private func drawTelemetry(in context: CGContext, sequence: UInt64) {
        let barWidth = CGFloat(width) * 0.28
        let barHeight = max(8, CGFloat(height) * 0.018)
        let progress = CGFloat(sequence % 180) / 180
        let origin = CGPoint(x: CGFloat(width) * 0.06, y: CGFloat(height) * 0.1)

        context.setFillColor(CGColor(red: 0.08, green: 0.12, blue: 0.2, alpha: 0.9))
        context.fill(
            CGRect(x: origin.x, y: origin.y, width: barWidth, height: barHeight)
        )
        context.setFillColor(CGColor(red: 0.25, green: 0.74, blue: 1, alpha: 1))
        context.fill(
            CGRect(x: origin.x, y: origin.y, width: barWidth * progress, height: barHeight)
        )

        context.setStrokeColor(CGColor(red: 0.38, green: 0.82, blue: 1, alpha: 0.75))
        context.setLineWidth(2)
        context.stroke(
            CGRect(
                x: CGFloat(width) * 0.055,
                y: CGFloat(height) * 0.065,
                width: CGFloat(width) * 0.34,
                height: CGFloat(height) * 0.1
            )
        )
    }
}

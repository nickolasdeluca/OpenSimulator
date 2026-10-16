import IOSurface
import Metal
import MetalKit
import SimulatorCore

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut screenVertex(uint id [[vertex_id]], constant uint &quarterTurns [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    const float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
    VertexOut out;
    out.position = float4(corners[id], 0, 1);
    // The framebuffer is always portrait, so a turned device is drawn by reading it turned.
    float2 uv = uvs[id];
    for (uint turn = 0; turn < quarterTurns; turn++) {
        uv = float2(uv.y, 1.0 - uv.x);
    }
    out.uv = uv;
    return out;
}

fragment float4 screenFragment(VertexOut in [[stage_in]], texture2d<float> screen [[texture(0)]]) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
    return screen.sample(linearSampler, in.uv);
}
"""

/// Draws the simulator's framebuffer. The texture wraps the `IOSurface` the guest renders into, so
/// a frame is never copied: drawing is one textured quad on the GPU.
/// Its state is guarded by `lock`, because frames arrive on the display stream's queue.
final class ScreenRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let lock = NSLock()
    private var texture: MTLTexture?
    private var surface: IOSurfaceRef?
    private var quarterTurns: UInt32 = 0

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw RendererError("Metal could not create a command queue.")
        }
        commandQueue = queue
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "screenFragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
    }

    var currentSurface: IOSurfaceRef? {
        lock.lock()
        defer { lock.unlock() }
        return surface
    }

    func setOrientation(_ orientation: DeviceOrientation) {
        lock.lock()
        quarterTurns = UInt32(orientation.quarterTurns)
        lock.unlock()
    }

    /// Called from the display stream's queue. The guest usually redraws into the same surface, so
    /// the texture is only rebuilt when the surface itself changes.
    func accept(_ newSurface: IOSurfaceRef) {
        lock.lock()
        defer { lock.unlock() }
        if let surface, CFEqual(surface, newSurface) { return }
        surface = newSurface
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: IOSurfaceGetWidth(newSurface),
            height: IOSurfaceGetHeight(newSurface),
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        texture = device.makeTexture(descriptor: descriptor, iosurface: newSurface, plane: 0)
    }

    func draw(in view: MTKView) {
        lock.lock()
        let current = texture
        var turns = quarterTurns
        lock.unlock()

        guard let current,
              let passDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

        let shown = turns % 2 == 0
            ? CGSize(width: current.width, height: current.height)
            : CGSize(width: current.height, height: current.width)
        let fitted = ScreenGeometry.fittedRect(container: view.drawableSize, content: shown)
        if fitted.width > 0, fitted.height > 0 {
            encoder.setViewport(MTLViewport(
                originX: fitted.minX, originY: fitted.minY,
                width: fitted.width, height: fitted.height,
                znear: 0, zfar: 1
            ))
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&turns, length: MemoryLayout<UInt32>.size, index: 0)
        encoder.setFragmentTexture(current, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

struct RendererError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

import SwiftUI
import MetalKit
import MetalPerformanceShaders

// The idle screen's oil, live: the splash's icon shot (transitive-bullshit/apple-music-effect, src/shaders.ts
// OPTICS + FINISH, ported to Metal) held at its settled moment and looped. The mark lies under a rounded-square
// dome of oil; each pixel's view ray refracts through it to the mark once per wavelength, so the steep rim
// smears the mark's edges into cyan, blue and violet, and a blue glow (bloom) sits around the bright parts.
// The dome breathes slowly and a wave leaves its edge every few seconds. Every motion is periodic: no seam.
// Settings are the splash's (its dark render: depth 0.35, max slope 0.7, dispersion 260, knee 0.35, reflect 0.5).
// When a song arrives, its album art fades in under the oil in place of the mark, on a fresh wave.

struct OilUniforms {
    var lens: SIMD4<Float>      // radius, height, superellipse exponent, reveal softness
    var profile: SIMD4<Float>   // crown, flat, shoulder, edge
    var ring: SIMD4<Float>      // edge wave: amplitude, width, -, how far outside the rim
    var view: SIMD4<Float>      // half width, half height (world), logo width (world), album mix
    var optics: SIMD4<Float>    // depth, ior, dispersion, dispersion knee
    var look: SIMD4<Float>      // max slope, reflect, softbox, bloom
}

final class OilRenderer {
    let device: MTLDevice
    let optics: MTLRenderPipelineState, finish: MTLRenderPipelineState
    let mark: MTLTexture
    var album: MTLTexture?
    var albumAt: Double?
    let sampler: MTLSamplerState
    let start = CACurrentMediaTime()
    var hdr: MTLTexture?, glow: MTLTexture?, glowWide: MTLTexture?

    init?(device: MTLDevice) {
        self.device = device
        guard let lib = try? device.makeLibrary(source: Self.source, options: nil) else { return nil }
        func pipe(_ f: String, _ fmt: MTLPixelFormat) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "oilVertex")
            d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = fmt
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let o = pipe("oilOptics", .rgba16Float), let f = pipe("oilFinish", .bgra8Unorm), let m = Self.texture(device, draw: { ctx, n in
            // the mark where the splash had it: its 757-unit viewBox spans the logo's width
            ctx.addPath(DuoMark().path(in: CGRect(x: 189, y: 201.5, width: 380, height: 355).applying(.init(scaleX: CGFloat(n) / 757, y: CGFloat(n) / 757))).cgPath)
            ctx.setFillColor(.white); ctx.fillPath()
        }) else { return nil }
        optics = o; finish = f; mark = m
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear; s.mipFilter = .linear
        sampler = device.makeSamplerState(descriptor: s)!
    }

    static func texture(_ device: MTLDevice, draw: (CGContext, Int) -> Void) -> MTLTexture? {
        let n = 1024
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(n)); ctx.scaleBy(x: 1, y: -1)   // top-left origin, like the SVG
        draw(ctx, n)
        return try? MTKTextureLoader(device: device).newTexture(cgImage: ctx.makeImage()!, options: [.generateMipmaps: true, .SRGB: true])
    }

    /// The album art, as a rounded square the size of the mark, under the oil.
    func setAlbum(_ image: NSImage?) {
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { album = nil; albumAt = nil; return }
        album = Self.texture(device) { ctx, n in
            let side = CGFloat(n) * 0.5, r = CGRect(x: (CGFloat(n) - side) / 2, y: (CGFloat(n) - side) / 2, width: side, height: side)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: side * 0.1, cornerHeight: side * 0.1, transform: nil)); ctx.clip()
            ctx.translateBy(x: 0, y: r.maxY + r.minY); ctx.scaleBy(x: 1, y: -1)   // CGImage draws bottom-up
            ctx.draw(cg, in: r)
        }
        albumAt = CACurrentMediaTime() - start
    }

    func uniforms(aspect: Float, time t: Double) -> OilUniforms {
        let a = albumAt.map { t - $0 }   // seconds since the album arrived
        // the edge wave: one every 4 s, travelling out and fading (sin² in and out); a new one starts with the album
        let period = 4.0
        let ph = Float(((a ?? t) / period).truncatingRemainder(dividingBy: 1))
        let wave = 0.02 * pow(sin(.pi * ph), 2) * (a.map { $0 < period ? 1.4 : 1 } ?? 1)
        // the dome breathes (7 s), and swells briefly as the album arrives
        let breathe = Float(sin(2 * .pi * t / 7))
        let swell = a.map { Float(exp(-$0 / 0.7) * (1 - exp(-$0 / 0.12))) } ?? 0
        let settle = 0.85 + 0.1 * breathe
        let mix = a.map { Float(smoothstep(min($0 / 1.0, 1))) } ?? 0
        let halfH: Float = 1.15   // zoomed out from the splash's crop (0.78) so the tile sits small, with room for the wave
        return OilUniforms(
            lens: [0.53 + 0.008 * breathe + 0.04 * swell, 0.22 * (1 + 0.07 * breathe + 0.5 * swell), 3.3, 0.06],
            profile: [0.4597 + (0.1004 - 0.4597) * settle, 45, 0.7245 + (0.4008 - 0.7245) * settle, 0.2],
            ring: [wave, 0.02, 0, 0.03 + 0.27 * ph],
            view: [halfH * aspect, halfH, 1.1156, mix],
            optics: [0.35, 1.47, 260, 0.35],
            look: [0.7, 0.5, 4, 0.12])
    }

    func draw(_ cb: MTLCommandBuffer, to target: MTLTexture, aspect: Float, time: Double? = nil) {
        let w = target.width, h = target.height
        if hdr?.width != w || hdr?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead, .shaderWrite]; d.storageMode = .private
            hdr = device.makeTexture(descriptor: d); glow = device.makeTexture(descriptor: d); glowWide = device.makeTexture(descriptor: d)
        }
        guard let hdr, let glow, let glowWide else { return }
        var u = uniforms(aspect: aspect, time: time ?? CACurrentMediaTime() - start)
        func pass(_ tex: MTLTexture, _ body: (MTLRenderCommandEncoder) -> Void) {
            let p = MTLRenderPassDescriptor()
            p.colorAttachments[0].texture = tex; p.colorAttachments[0].loadAction = .dontCare; p.colorAttachments[0].storeAction = .store
            guard let e = cb.makeRenderCommandEncoder(descriptor: p) else { return }
            body(e); e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding()
        }
        pass(hdr) { e in
            e.setRenderPipelineState(optics)
            e.setFragmentBytes(&u, length: MemoryLayout<OilUniforms>.stride, index: 0)
            e.setFragmentTexture(mark, index: 0); e.setFragmentTexture(album ?? mark, index: 1)
            e.setFragmentSamplerState(sampler, index: 0)
        }
        // the glow: a tight and a wide blur of the frame (the original sums a mip pyramid)
        MPSImageGaussianBlur(device: device, sigma: Float(h) * 0.012).encode(commandBuffer: cb, sourceTexture: hdr, destinationTexture: glow)
        MPSImageGaussianBlur(device: device, sigma: Float(h) * 0.05).encode(commandBuffer: cb, sourceTexture: hdr, destinationTexture: glowWide)
        pass(target) { e in
            e.setRenderPipelineState(finish)
            e.setFragmentBytes(&u, length: MemoryLayout<OilUniforms>.stride, index: 0)
            e.setFragmentTexture(hdr, index: 0); e.setFragmentTexture(glow, index: 1); e.setFragmentTexture(glowWide, index: 2)
            e.setFragmentSamplerState(sampler, index: 0)
        }
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct U { float4 lens, profile, ring, view, optics, look; };
    struct V { float4 pos [[position]]; float2 uv; };

    vertex V oilVertex(uint i [[vertex_id]]) {
        float2 p = float2((i << 1) & 2, i & 2);
        return { float4(p * 2.0 - 1.0, 0.0, 1.0), float2(p.x, 1.0 - p.y) };   // uv: y down, like the texture
    }

    float hash(float2 p) {
        float3 p3 = fract(float3(p.xyx) * 0.1031);
        p3 += dot(p3, p3.yzx + 33.33);
        return fract((p3.x + p3.y) * p3.z);
    }

    float rhoAt(float2 o, constant U& u) {
        float2 d = abs(o) / u.lens.x;
        return pow(pow(d.x, u.lens.z) + pow(d.y, u.lens.z), 1.0 / u.lens.z);
    }

    // the dome (lensZ): a superellipse footprint, round crown and shoulder, steep rim, a wave on its edge
    float surface(float2 o, constant U& u) {
        float2 d = abs(o) / u.lens.x;
        float rho = rhoAt(o, u);
        float dist = length(o) * (1.0 - 1.0 / max(rho, 1e-4));
        float e = (dist - u.ring.w) / max(u.ring.y, 1e-4);
        float z = u.ring.x * exp(-e * e);
        if (rho >= 1.0) return z;
        float r2 = dot(d, d);
        return z + u.lens.y * exp(-u.profile.x * r2 - u.profile.z * r2 * r2) * pow(1.0 - pow(rho, u.profile.y), u.profile.w);
    }

    float lobe(float x, float mu, float s1, float s2) { float t = (x - mu) / (x < mu ? s1 : s2); return exp(-0.5 * t * t); }

    // CIE 1931 colour matching (Wyman et al.'s fit) to linear sRGB
    float3 spectrum(float lambda) {
        float l = lambda * 1000.0;
        float x = 1.056 * lobe(l, 599.8, 37.9, 31.0) + 0.362 * lobe(l, 442.0, 16.0, 26.7) - 0.065 * lobe(l, 501.1, 20.4, 26.2);
        float y = 0.821 * lobe(l, 568.8, 46.9, 40.5) + 0.286 * lobe(l, 530.9, 16.3, 31.1);
        float z = 1.217 * lobe(l, 437.0, 11.8, 36.0) + 0.681 * lobe(l, 459.0, 26.0, 13.8);
        return float3x3(float3(3.2406, -0.9689, 0.0557), float3(-1.5372, 1.8758, -0.2040), float3(-0.4986, 0.0415, 1.0570)) * float3(x, y, z);
    }

    // the dark studio: a key softbox left of the camera, a dim fill right, the walls at grazing angles
    float3 env(float3 r, constant U& u) {
        if (r.z <= 0.0) return float3(0.0);
        float2 s = r.xy / max(r.z, 0.05);
        float key = 1.0 - smoothstep(0.0, 0.3, length(max(abs(s - float2(-1.5, 0.1)) - float2(0.25, 0.55), 0.0)));
        float fill = 1.0 - smoothstep(0.0, 0.4, length(max(abs(s - float2(1.8, -0.2)) - float2(0.2, 0.7), 0.0)));
        return float3(0.95, 0.97, 1.0) * (u.look.z * (key + 0.25 * fill) + 1.2 * smoothstep(1.2, 4.0, length(s)));   // walls dimmed: they drew a grey outline round the tile
    }

    fragment float4 oilOptics(V in [[stage_in]], constant U& u [[buffer(0)]],
                              texture2d<float> mark [[texture(0)]], texture2d<float> album [[texture(1)]], sampler smp [[sampler(0)]]) {
        float2 p = (float2(in.uv.x, 1.0 - in.uv.y) * 2.0 - 1.0) * u.view.xy;
        float3 Vd = float3(0.0, 0.0, -1.0);
        const float h = 0.0015;
        float z = surface(p, u);
        float2 grad = float2(surface(p + float2(h, 0), u) - surface(p - float2(h, 0), u),
                             surface(p + float2(0, h), u) - surface(p - float2(0, h), u)) / (2.0 * h);
        grad *= min(1.0, u.look.x / max(length(grad), 1e-6));   // oil meets glass at its contact angle
        float3 N = normalize(float3(-grad, 1.0));

        float depth = u.optics.x, n589 = u.optics.y;
        float g2 = dot(grad, grad), k2 = u.optics.w * u.optics.w;
        float disp = u.optics.z * g2 / (g2 + k2);   // colour gathers on the steep rim; the interior stays clean

        float jitter = hash(in.pos.xy);
        float3 acc = 0.0, wsum = 0.0;
        const int count = 32;
        for (int i = 0; i < count; i++) {
            float lambda = mix(0.38, 0.72, (float(i) + jitter) / float(count));
            float3 w = spectrum(lambda);
            float n = n589 + 0.0044 * disp * (1.0 / (lambda * lambda) - 1.0 / (0.5893 * 0.5893));
            float3 T = refract(Vd, N, 1.0 / n);
            float2 q = p + T.xy * (z + depth) / max(-T.z, 1e-3);
            float2 luv = q / u.view.z + 0.5;
            float4 L = 0.0;
            if (all(luv >= 0.0) && all(luv <= 1.0)) {
                float2 tuv = float2(luv.x, 1.0 - luv.y);
                L = mix(mark.sample(smp, tuv), album.sample(smp, tuv), u.view.w);
            }
            L *= 1.0 - smoothstep(1.0 - u.lens.w, 1.0, rhoAt(q, u));   // lit only where the dome has reached
            acc += w * (float3(0.0012, 0.0014, 0.002) * (1.0 - L.a) + float3(0.93, 0.95, 1.0) * L.rgb);
            wsum += w;
        }
        float3 col = acc / wsum;
        float lum = dot(col, float3(0.2126, 0.7152, 0.0722));
        float lowest = min(col.r, min(col.g, col.b));
        if (lowest < 0.0) col = lum > 0.0 ? mix(float3(lum), col, lum / (lum - lowest)) : float3(0.0);

        float r0 = pow((n589 - 1.0) / (n589 + 1.0), 2.0);
        float F = r0 + (1.0 - r0) * pow(1.0 - clamp(N.z, 0.0, 1.0), 5.0);
        col = col * (1.0 - F) + u.look.y * F * env(reflect(Vd, N), u);
        return float4(col, 1.0);
    }

    float3 toSrgb(float3 c) { return select(c * 12.92, 1.055 * pow(c, 1.0 / 2.4) - 0.055, c > 0.0031308); }

    // the film's grade: a blue glow, cool whites, a vignette, richer colour, a soft shoulder, crushed blacks
    fragment float4 oilFinish(V in [[stage_in]], constant U& u [[buffer(0)]], texture2d<float> src [[texture(0)]],
                              texture2d<float> glow [[texture(1)]], texture2d<float> wide [[texture(2)]], sampler smp [[sampler(0)]]) {
        float3 c = src.sample(smp, in.uv).rgb;
        c += u.look.w * float3(0.55, 0.75, 1.35) * (glow.sample(smp, in.uv).rgb + wide.sample(smp, in.uv).rgb);
        c *= float3(0.97, 1.0, 1.03);
        float2 v = (in.uv - 0.5) * float2(u.view.x / u.view.y, 1.0);
        c *= 1.0 - 0.25 * dot(v, v);
        float lum = dot(c, float3(0.2126, 0.7152, 0.0722));
        c = max(float3(lum) + (c - float3(lum)) * 1.5, 0.0);
        float3 over = max(c - 0.8, 0.0);
        c = min(c, 0.8) + over / (1.0 + over / 0.2);
        float3 s = toSrgb(clamp(c, 0.0, 1.0));
        s = max(s - 0.012, 0.0) / (1.0 - 0.012);
        return float4(s, 1.0);
    }
    """
}

struct OilRipple: NSViewRepresentable {
    var album: NSImage?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = false
        v.preferredFramesPerSecond = 60
        if let device = v.device { context.coordinator.renderer = OilRenderer(device: device) }
        context.coordinator.queue = v.device?.makeCommandQueue()
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        guard album !== context.coordinator.album else { return }
        context.coordinator.album = album
        context.coordinator.renderer?.setAlbum(album)
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        var renderer: OilRenderer?
        var queue: MTLCommandQueue?
        var album: NSImage?
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard let r = renderer, let drawable = view.currentDrawable, let cb = queue?.makeCommandBuffer() else { return }
            let s = view.drawableSize
            r.draw(cb, to: drawable.texture, aspect: Float(s.width / max(s.height, 1)))
            cb.present(drawable)
            cb.commit()
        }
    }
}

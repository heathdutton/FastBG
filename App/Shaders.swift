/// Compiled at runtime with `makeLibrary(source:)`, which needs no `metal` compiler at build time. The first launch
/// pays about 100 ms; after that Metal's disk cache brings it down to about a millisecond.
///
/// All colour work happens in gamma-encoded 8-bit space: camera, decoded video and web frames arrive that way and
/// stills load with SRGB off, so nothing linearizes on sample and untouched pixels pass through bit for bit.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; float2 uv; };

    // One oversized triangle covers the viewport; uv has a top-left origin to match texture space.
    vertex VOut fullscreenVS(uint vid [[vertex_id]]) {
        float2 p = float2(float((vid << 1) & 2), float(vid & 2));
        VOut o;
        o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    // Mirrors CompositeUniforms in Swift.
    struct CompositeUniforms {
        float4 camXform;    // xy scale, zw offset: sourceUV = uv * xy + zw, the aspect-fill crop
        float4 fromXform;
        float4 toXform;
        float4 keyRGB;      // the screen's colour, removed from edge pixels in proportion to how much screen they hold
        float  dissolve;    // eased 0..1; 0 samples only `from`
        float  featherPx;   // mask edge width in output px
        float  edge;        // mask level that becomes alpha 0.5
        uint   flags;       // bit0 key, bit1 background only, bit2 no Vision (the key alone decides), bit4 screen map,
                            // bit5 last frame's key is valid, bit6 plate, bit7 mask is refinement coefficients
        float2 keyCbCr;
        float  keyNear;
        float  keyFar;
        uint   spill;       // 0 none, 1 green, 2 blue
        float  fromCamera;  // share of the live camera mixed into a frozen `from` or `to`
        float  toCamera;
        float  keyBlur;     // camera px out to the taps the key's colour is averaged over
        float  keyStill;    // how much of the new key a still pixel takes each frame; 1 turns smoothing off
        float  plateMix;    // 0 keys against one screen colour, 1 against the plate's colour at that spot
        float  despill;
        float  motionLo;    // brightness change below this is sensor noise
        float  motionHi;    // above this it's movement, which takes the new key outright
        float2 keyTurn;     // cos and sin of the user's turn of the screen's hue
        float  edgeSoft;    // half the width, in mask levels, of the fade across Vision's edge
        float  keyLinear;   // 0 keys by chroma distance, 1 by colour difference, which is linear in true alpha
        float  keyShift;    // the key's edge slider, in half ramp widths
        float  keyWidth;    // the key's softness slider, a scale on its ramp
    };

    constexpr sampler lin(filter::linear, address::clamp_to_edge);

    static float2 chroma(float3 c) {
        return float2(dot(c, float3(-0.1146, -0.3854, 0.5)), dot(c, float3(0.5, -0.4542, -0.0458)));
    }

    struct Shaded { half4 color; half2 key; };

    // Up to 1 the screen's channel is held to the brighter of the other two, a light touch. From 1 to 2 the limit
    // falls to their average, the strong despill keyers use. What comes out goes back as neutral brightness, so a
    // despilled edge doesn't go dark.
    static float3 despill(float3 f, uint spill, float amount) {
        if (spill == 0u || amount <= 0.0) { return f; }
        float3 g = spill == 1u ? f : f.rbg;
        float limit = mix(max(g.r, g.b), 0.5 * (g.r + g.b), saturate(amount - 1.0));
        float removed = max(g.g - limit, 0.0) * saturate(amount);
        g.g -= removed;
        g = saturate(g + removed * (spill == 1u ? 0.587 : 0.114));
        return spill == 1u ? g : g.rbg;
    }

    static Shaded shade(VOut in, texture2d<half> cam, texture2d<half> mask, texture2d<half> bgFrom,
                        texture2d<half> bgTo, texture2d<half> matte, texture2d<half> screen,
                        texture2d<half> plate, texture2d<half> prior, constant CompositeUniforms& u) {
        float2 camUV = in.uv * u.camXform.xy + u.camXform.zw;
        half3 c = cam.sample(lin, camUV).rgb;
        half3 room = c;
        Shaded out;
        out.key = half2(0.0h);

        // The mask spans the camera frame, so it shares the camera's UVs. Derivatives are taken before any
        // branch so they stay defined across the quad.
        float m;
        if (u.flags & 128u) {
            // Coefficients fitted at the mask's size, applied to the full-size camera colour, so the edge lands on
            // the picture's own edge instead of Vision's coarse outline.
            half4 fit = mask.sample(lin, camUV);
            m = float(dot(fit.rgb, c) + fit.a);
        } else {
            m = float(mask.sample(lin, camUV).r);
        }
        float w = max(fwidth(m) * u.featherPx * 0.5, max(u.edgeSoft, 1e-4));
        float a = saturate((m - u.edge) / (2.0 * w) + 0.5);
        if (u.flags & 4u) { a = 1.0; }

        if (u.flags & 1u) {
            float3 f = float3(c);
            // Sensor noise jitters each pixel's colour, which makes hair edges shimmer, so the key reads the
            // colour of a small neighbourhood. The foreground keeps its own sharp pixels.
            float3 probe = f;
            if (u.keyBlur > 0.0) {
                float2 o = u.keyBlur / float2(cam.get_width(), cam.get_height());
                probe = (f + float3(cam.sample(lin, camUV - o).rgb) + float3(cam.sample(lin, camUV + o).rgb)
                         + float3(cam.sample(lin, camUV + float2(o.x, -o.y)).rgb)
                         + float3(cam.sample(lin, camUV + float2(-o.x, o.y)).rgb)) * 0.2;
            }
            // The screen's colour at this spot, since light falls off across a screen.
            float3 screenRGB = u.keyRGB.rgb;
            float2 screenCbCr = u.keyCbCr;
            if (u.flags & 64u) {
                float3 here = float3(plate.sample(lin, camUV).rgb);
                screenRGB = mix(screenRGB, here, u.plateMix);
                screenCbCr = mix(screenCbCr, chroma(here), u.plateMix);
            }
            screenCbCr = float2(screenCbCr.x * u.keyTurn.x - screenCbCr.y * u.keyTurn.y,
                                screenCbCr.x * u.keyTurn.y + screenCbCr.y * u.keyTurn.x);
            float k = smoothstep(u.keyNear, u.keyFar, distance(chroma(probe), screenCbCr));
            if (u.keyLinear > 0.0) {
                // How far the screen's channel stands above the average of the other two, against how far it
                // stands on the screen itself (Vlahos, Keylight, Nuke's IBK). A pixel that's part screen stands
                // above in proportion, so a wisp of hair keeps its share instead of rounding to nothing.
                float3 p = u.spill == 2u ? probe.rbg : probe, s = u.spill == 2u ? screenRGB.rbg : screenRGB;
                float lead = s.g - 0.5 * (s.r + s.b);
                float difference = lead > 0.02 ? 1.0 - (p.g - 0.5 * (p.r + p.b)) / lead : k;
                float lo = clamp(0.08 + 0.15 * u.keyShift, 0.0, 0.5), hi = min(1.0, lo + 0.84 * u.keyWidth);
                k = mix(k, saturate((difference - lo) / max(hi - lo, 0.05)), u.keyLinear);
            }
            // Where the picture hasn't changed, the key is averaged over frames. Where it moved, the new key is
            // taken as is, so nothing trails a moving head.
            float luma = dot(probe, float3(0.299, 0.587, 0.114));
            if (u.flags & 32u) {
                half2 before = prior.read(uint2(in.pos.xy)).rg;
                // A big jump in the key is movement too: someone crossing the screen can swap spots between them
                // and green at much the same brightness, and averaging those left a trail of half-keyed green.
                float moved = max(smoothstep(u.motionLo, u.motionHi, abs(luma - float(before.g))),
                                  smoothstep(0.25, 0.5, abs(k - float(before.r))));
                k = mix(float(before.r), k, mix(u.keyStill, 1.0, moved));
            }
            out.key = half2(k, luma);
            // An edge pixel is k parts foreground and 1 - k parts screen. Taking the screen's share back out
            // leaves the hair's own colour instead of a green or olive fringe.
            f = clamp((f - (1.0 - k) * screenRGB) / max(k, 0.02), 0.0, 1.0);
            f = despill(f, u.spill, u.despill);
            // Where the screen is behind the person the key decides, fenced by the dilated Vision matte so it can't
            // pass the room. Elsewhere Vision's own edge does, with no halo of room and no despilled clothes. The
            // key only takes over on the screen side of the map's soft edge, so room beside the screen never gets
            // the key's say.
            float s = (u.flags & 16u) ? smoothstep(0.5, 1.0, float(screen.sample(lin, camUV).r)) : 1.0;
            float fence = (u.flags & 4u) ? 1.0 : smoothstep(0.15, 0.85, float(matte.sample(lin, camUV).r));
            // Where the matte is sure it's the person, the key can't take anything away: a blue shirt in front of a
            // blue screen stays solid, on either side of the map's edge, and keeps its own colour rather than an
            // unmixed one. Around the edge the key decides, where it's sharper than any matte. With no matte, the
            // screen filling the background, it decides alone.
            float sure = (u.flags & 4u) ? 0.0 : smoothstep(0.7, 0.95, a);
            float keyed = max(min(k, fence), sure);
            float3 colour = mix(f, despill(float3(c), u.spill, u.despill), sure);
            a = mix(min(a, keyed), keyed, s);
            c = half3(mix(float3(c), colour, s));
        }
        if (u.flags & 2u) { a = 0.0; }

        half3 bg = mix(bgFrom.sample(lin, in.uv * u.fromXform.xy + u.fromXform.zw).rgb, room, half(u.fromCamera));
        if (u.dissolve > 0.0) {
            half3 to = mix(bgTo.sample(lin, in.uv * u.toXform.xy + u.toXform.zw).rgb, room, half(u.toCamera));
            bg = mix(bg, to, half(u.dissolve));
        }
        out.color = half4(mix(bg, c, half(a)), 1.0h);
        return out;
    }

    fragment half4 compositeFS(VOut in [[stage_in]],
                               texture2d<half> cam    [[texture(0)]],
                               texture2d<half> mask   [[texture(1)]],
                               texture2d<half> bgFrom [[texture(2)]],
                               texture2d<half> bgTo   [[texture(3)]],
                               texture2d<half> matte  [[texture(4)]],
                               texture2d<half> screen [[texture(5)]],
                               texture2d<half> plate  [[texture(6)]],
                               texture2d<half> prior  [[texture(7)]],
                               constant CompositeUniforms& u [[buffer(0)]]) {
        return shade(in, cam, mask, bgFrom, bgTo, matte, screen, plate, prior, u).color;
    }

    struct KeyedOut { half4 color [[color(0)]]; half2 key [[color(1)]]; };

    // The keyed composite also leaves each pixel's key and brightness for the next frame to average over.
    fragment KeyedOut compositeKeyedFS(VOut in [[stage_in]],
                                       texture2d<half> cam    [[texture(0)]],
                                       texture2d<half> mask   [[texture(1)]],
                                       texture2d<half> bgFrom [[texture(2)]],
                                       texture2d<half> bgTo   [[texture(3)]],
                                       texture2d<half> matte  [[texture(4)]],
                                       texture2d<half> screen [[texture(5)]],
                                       texture2d<half> plate  [[texture(6)]],
                                       texture2d<half> prior  [[texture(7)]],
                                       constant CompositeUniforms& u [[buffer(0)]]) {
        Shaded s = shade(in, cam, mask, bgFrom, bgTo, matte, screen, plate, prior, u);
        return KeyedOut { s.color, s.key };
    }

    struct TemporalUniforms {
        float stillWeight;  // how much of the new mask a still pixel takes each frame; 1 turns smoothing off
        float motionLo;     // luma change below this is sensor noise
        float motionHi;     // luma change above this is movement, which takes the new mask outright
        float edge;         // the mask level that counts as the person
        float hysteresis;   // how far past `edge` the averaged mask must go to switch a spot in or out
        uint  reset;
        float soft;         // the composite's fade across the edge, which an unsteady spot is held clear of
        float roomNear;     // colour distance from the learned room within which a spot still is the room
        float roomGain;     // how fast a spot's room colour becomes trusted, per frame
        float roomHold;     // 0 ignores the learned room, 1 lets it overrule an unsure mask fully
    };

    // Vision judges every frame afresh, so anything it scores near the edge, like a chair back, flips in and out.
    //
    // - Where the camera image hasn't changed, the mask is averaged over time. Where it moved, the new mask is taken
    //   as is, so nothing trails behind a moving head.
    // - Averaging alone leaves a flip-flopping spot hovering around the edge, which still flickers. So each spot
    //   remembers whether it's in or out, and only switches once the average clears the edge by `hysteresis`.
    //
    // Only an edge keeps an in-between value, which the composite fades across. A spot Vision keeps changing its mind
    // about, or a broad patch it's evenly unsure of like a chair, is pushed clear of the fade, in or out, rather
    // than left ghostly. Hair sits where the mask drops steeply, and keeps its in-between value.
    //
    // The state texture holds the decided value (r), the average (g), in-or-out (b) and unsteadiness (a). The
    // decided value also goes out on its own, with the camera's colour at the mask's size to fit the refinement to,
    // and in-or-out for the green screen's garbage matte. The learned room goes out as colour and trust.
    kernel void temporalMask(texture2d<half, access::read> fresh [[texture(0)]],
                             texture2d<half, access::read> before [[texture(1)]],
                             texture2d<half, access::write> after [[texture(2)]],
                             texture2d<half, access::sample> cam [[texture(3)]],
                             texture2d<half, access::read> lumaBefore [[texture(4)]],
                             texture2d<half, access::write> lumaAfter [[texture(5)]],
                             texture2d<half, access::write> decidedOut [[texture(6)]],
                             texture2d<half, access::write> guide [[texture(7)]],
                             texture2d<half, access::write> insideOut [[texture(8)]],
                             texture2d<half, access::read> roomBefore [[texture(9)]],
                             texture2d<half, access::write> roomAfter [[texture(10)]],
                             constant TemporalUniforms& u [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        uint w = after.get_width(), h = after.get_height();
        if (gid.x >= w || gid.y >= h) { return; }
        // The mask spans the camera frame, so a mask texel's own UV finds its spot in the camera image. Four taps
        // average the camera over the texel instead of point-sampling a 1080p frame.
        float2 texel = 1.0 / float2(w, h);
        float2 uv = (float2(gid) + 0.5) * texel;
        half3 c = cam.sample(lin, uv + texel * float2(-0.25, -0.25)).rgb
                + cam.sample(lin, uv + texel * float2(0.25, -0.25)).rgb
                + cam.sample(lin, uv + texel * float2(-0.25, 0.25)).rgb
                + cam.sample(lin, uv + texel * float2(0.25, 0.25)).rgb;
        float3 colour = float3(c) * 0.25;
        float luma = dot(colour, float3(0.299, 0.587, 0.114));
        float m = float(fresh.read(gid).r);

        // The camera doesn't move during a call, so the room behind the person can be learned: each spot's colour
        // wherever it's been confidently room and still. A spot that still matches it is the room, whatever Vision
        // says, unless Vision is sure it's a person, which keeps a white shirt in front of a white wall.
        float4 room = u.reset == 0u ? float4(roomBefore.read(gid)) : float4(colour, 0.0);
        float3 gap3 = abs(colour - room.rgb);
        float gap = max(gap3.r, max(gap3.g, gap3.b));
        float match = room.a * (1.0 - smoothstep(u.roomNear, 2.0 * u.roomNear, gap)) * u.roomHold;
        m *= 1.0 - match * (1.0 - smoothstep(0.85, 0.97, m));
        float average = m;
        float inside = m > u.edge ? 1.0 : 0.0;
        float unsteady = 0.0;
        if (u.reset == 0u) {
            float4 prior = float4(before.read(gid));
            float moved = smoothstep(u.motionLo, u.motionHi, abs(luma - float(lumaBefore.read(gid).r)));
            // Only change without movement counts: a moving edge is supposed to change.
            unsteady = mix(prior.a, abs(m - prior.g) * (1.0 - moved), mix(0.2, 1.0, moved));
            average = mix(prior.g, m, mix(u.stillWeight, 1.0, moved));
            inside = prior.b;
            if (inside < 0.5 && average > u.edge + u.hysteresis) { inside = 1.0; }
            else if (inside > 0.5 && average < u.edge - u.hysteresis) { inside = 0.0; }
        }
        // Held past the edge on the decided side, so the composite agrees with the decision: just past for a steady
        // spot, whose in-between value is real, and clear of the whole fade for an unsteady one.
        // Slope across about 1/128 of the frame either way. A true matte, finer than Vision's 512-wide mask, is
        // soft where it means to be, so only a coarse mask's flat patches are pushed.
        int2 g = int2(gid), last = int2(w - 1, h - 1), reach = int2(max(2u, w / 256u), max(2u, h / 192u));
        float slope = abs(float(fresh.read(uint2(clamp(g + int2(reach.x, 0), 0, last))).r)
                          - float(fresh.read(uint2(clamp(g - int2(reach.x, 0), 0, last))).r))
                    + abs(float(fresh.read(uint2(clamp(g + int2(0, reach.y), 0, last))).r)
                          - float(fresh.read(uint2(clamp(g - int2(0, reach.y), 0, last))).r));
        float flat = w <= 1024u ? 1.0 - smoothstep(0.15, 0.4, slope) : 0.0;
        float margin = mix(0.02, max(u.soft, 0.02), max(smoothstep(0.1, 0.3, unsteady), flat));
        float decided = inside > 0.5 ? max(average, u.edge + margin) : min(average, u.edge - margin);
        after.write(half4(decided, average, inside, unsteady), gid);
        float still = u.reset == 0u ? 1.0 - smoothstep(u.motionLo, u.motionHi,
                                                        abs(luma - float(lumaBefore.read(gid).r))) : 0.0;
        // Near zero only, so a matte's faintest wisps of hair are never learned as room.
        if (inside < 0.5 && average < 0.05 && still > 0.5) {
            room.rgb = mix(room.rgb, colour, room.a < 0.05 ? 1.0 : 0.1);
            room.a = min(1.0, room.a + u.roomGain);
        }
        roomAfter.write(half4(room), gid);
        lumaAfter.write(half4(luma), gid);
        decidedOut.write(half4(decided), gid);
        guide.write(half4(c * 0.25h, 1.0h), gid);
        // The garbage matte grows from here. A true matte's faintest hair is real, so it counts from any support; a
        // coarse mask's in-or-out is its steadiest line.
        insideOut.write(half4(w > 1024u ? step(0.08, average) : inside), gid);
    }

    struct FreezeUniforms { float4 aXform; float4 bXform; float t; };

    // Bakes an in-flight dissolve into one texture, so the next dissolve starts from exactly what was on screen.
    fragment half4 freezeFS(VOut in [[stage_in]],
                            texture2d<half> a [[texture(0)]],
                            texture2d<half> b [[texture(1)]],
                            constant FreezeUniforms& u [[buffer(0)]]) {
        half3 x = a.sample(lin, in.uv * u.aXform.xy + u.aXform.zw).rgb;
        half3 y = b.sample(lin, in.uv * u.bXform.xy + u.bXform.zw).rgb;
        return half4(mix(x, y, half(u.t)), 1.0h);
    }
    """
}

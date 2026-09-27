import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let tileWidth: CGFloat = 110
private let tileHeight = tileWidth * 9 / 16
private let spacing: CGFloat = 8

/// The window's content, laid out like a Control Center module. The 16:9 thumbnail grid runs three to a row, with
/// the settings folded away under it.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: Library
    @ObservedObject var setup: Setup
    let openSetup: () -> Void
    @StateObject private var reorder = Reorder()
    /// Remembered across launches, like the rest of the settings.
    @AppStorage("settingsOpen") private var settingsOpen = false
    /// Settings open or shut from the start, for the harness's pictures of it. Nil keeps what was remembered.
    var startExpanded: Bool?

    private let columns = Array(repeating: GridItem(.fixed(tileWidth), spacing: spacing), count: 3)
    private static let dropTypes: [UTType] = [.fastbgTile, .fileURL, .url, .plainText]
    private static let inset: CGFloat = 14

    /// Whole percents, rounded down. Under 1% reads "<1%", so work that's going on never shows as none, but the
    /// crumbs an idle app leaves still read 0%.
    private static func percent(_ value: Double) -> String {
        value >= 0.05 && value < 1 ? "<1%" : "\(Int(value.rounded(.down)))%"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: Self.inset)

            Group {
                // Past five rows the grid scrolls, so the footer stays on screen.
                if (library.items.count + model.pending.count + 2 + 2) / 3 > 5 {
                    ScrollView { grid }.frame(height: tileHeight * 5 + spacing * 4.5)
                } else {
                    grid
                }
            }
            .padding(.horizontal, Self.inset)
            .padding(.bottom, Self.inset - 4)

            if model.systemBackground, library.selected != Library.offID {
                Row {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("macOS Background is on too")
                    Spacer()
                    Button("Turn off", action: model.showVideoEffects).controlSize(.small)
                }
            }
            // Everything FastBG does by itself, folded away like a Control Center module till it's wanted.
            DisclosureRow(title: "Settings", expanded: $settingsOpen)
            if settingsOpen {
                settings.padding(.top, 4)
            }
            if !setup.allDone {
                MenuRow("Finish setup...", action: openSetup).padding(.top, settingsOpen ? 8 : 0)
            }
            Spacer().frame(height: Self.inset - 4)
        }
        .font(.system(size: 13))
        .frame(width: tileWidth * 3 + spacing * 2 + Self.inset * 2)
        // Pinned to the top, so the grid stays put while the window catches up with a change of height.
        .frame(maxHeight: .infinity, alignment: .top)
        .onDrop(of: Self.dropTypes, delegate: TileDrop(target: .panel, model: model, reorder: reorder))
        .onAppear { if let startExpanded { settingsOpen = startExpanded } }
        .background { WindowDragArea() }
        .background {
            // Zero-size buttons are the one shortcut target that works in a panel like this: ⌘V pastes a URL, ⌘W
            // closes the window and ⌘Q quits, since an app with no Dock icon has no menu bar to hold them.
            Group {
                Button("") { model.paste() }.keyboardShortcut("v", modifiers: .command)
                Button("") { NSApp.keyWindow?.performClose(nil) }.keyboardShortcut("w", modifiers: .command)
                Button("") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: spacing) {
            Tile(active: library.selected == Library.offID) {
                Text("Off").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
            .onTapGesture { model.select(Library.offID) }
            .onDrop(of: Self.dropTypes, delegate: TileDrop(target: .off, model: model, reorder: reorder))
            .accessibilityLabel("Off")
            .accessibilityAddTraits(.isButton)

            ForEach(library.items) { item in
                Tile(active: library.selected == item.id, kind: item.kind,
                     deletable: true, available: model.isAvailable(item), onDelete: { model.delete(item.id) }) {
                    Thumbnail(image: model.thumbnail(item.id), kind: item.kind,
                              loop: model.windowVisible ? model.loop(item.id) : nil)
                }
                .opacity(reorder.dragging == item.id && reorder.slot != nil ? 0.4 : 1)
                .overlay(alignment: .leading) {
                    if reorder.marks(before: item.id, in: library.items) {
                        InsertionMark().offset(x: -spacing / 2 - 1.5)
                    }
                }
                .overlay(alignment: .trailing) {
                    if reorder.marks(after: item.id, in: library.items) {
                        InsertionMark().offset(x: spacing / 2 + 1.5)
                    }
                }
                .onTapGesture { model.select(item.id) }
                .onDrag {
                    reorder.dragging = item.id
                    return model.dragProvider(for: item)
                }
                .onDrop(of: Self.dropTypes,
                        delegate: TileDrop(target: .item(item.id), model: model, reorder: reorder))
                .accessibilityLabel(item.kind == .web ? "Web page" : item.kind == .video ? "Video" : "Image")
                .accessibilityAddTraits(.isButton)
            }

            ForEach(model.pending) { pending in
                Tile(active: false, kind: pending.kind) {
                    ProgressView().controlSize(.small)
                }
            }

            Tile(active: false) {
                Image(systemName: "plus").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
            }
            .onTapGesture { model.openPicker() }
            .onDrop(of: Self.dropTypes, delegate: TileDrop(target: .end, model: model, reorder: reorder))
            .accessibilityLabel("Add a background")
            .accessibilityAddTraits(.isButton)
        }
        .onDrop(of: Self.dropTypes, delegate: TileDrop(target: .gap, model: model, reorder: reorder))
    }
}

/// A full-width row with the panel's insets.
private struct Row<Content: View>: View {
    /// What the row does, behind an info icon at its right edge.
    var info: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 6) {
            content()
            if let info { InfoIcon(text: info).padding(.leading, 2) }
        }
            .frame(minHeight: 26)
            .padding(.horizontal, 14)
    }
}

extension PanelView {
    /// Camera, Turbo with the usage meter, Autocalibrate, the screen, the matte and every tuning slider.
    @ViewBuilder private var settings: some View {
        if model.cameras.count > 1 {
            Row(info: "Which camera FastBG reads. Automatic takes an external camera first, then the built-in "
                + "one, then an iPhone, and skips a closed lid's.") {
                Text("Camera")
                Spacer()
                Picker("Camera", selection: Binding(get: { model.cameraChoice }, set: { model.setCamera($0) })) {
                    Text(model.automaticCamera.map { "Automatic (\($0))" } ?? "Automatic").tag("")
                    Divider()
                    ForEach(model.cameras) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .focusEffectDisabled()
                .fixedSize()
            }
        }
        Row(info: "Spends more of your Mac on a slightly better picture, best plugged in. When dim light slows the "
            + "camera, FastBG fills in the missing frames for a smooth 30 fps, a couple of frames behind. It also "
            + "cuts you out afresh every frame and follows a green screen's light three times as often. Apps that "
            + "send video under 30 fps anyway, like many web calls, may not show the difference. The numbers are "
            + "FastBG's own share of the whole CPU and GPU. NE ✓ means the cutout is running on the Neural Engine, "
            + "which macOS doesn't measure per app.") {
            Text("Turbo")
            if let u = model.usage {
                Text("CPU \(Self.percent(u.cpu)), GPU \(Self.percent(u.gpu))" + (u.neural ? ", NE ✓" : "")
                     + (model.turboFill.map { ", \(Int($0.rounded()))→30 fps" } ?? ""))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("Turbo", isOn: Binding(get: { model.turbo }, set: { model.setTurbo($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .onAppear { model.watchUsage(true) }
        .onDisappear { model.watchUsage(false) }
        Row(info: "Sets the sliders from your camera's noise and how much the matte flickers, every 2 s, and finds "
            + "a green or blue screen. Drag a slider to lean its pick your way, and the arrow undoes every lean.") {
            Text("Autocalibrate")
            if let r = model.readings {
                Text(String(format: "noise %.1f%%, flicker %.1f%%", r.noise.luma * 100, r.flicker / 10))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.auto, !model.offsets.isEmpty {
                Button(action: model.resetOffsets) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reset the sliders to Autocalibrate's picks")
            }
            Toggle("Autocalibrate", isOn: Binding(get: { model.auto }, set: { model.setAuto($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        Row(info: "Keys out a green or blue screen behind you, in the shade the dot shows. With Autocalibrate on "
            + "it finds either by itself. Your picture's edges come from the matte everywhere else.") {
            Text("Screen")
            if let rgb = model.screenRGB {
                Circle()
                    .fill(Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z)))
                    .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                    .frame(width: 11, height: 11)
            } else if !model.auto, model.greenScreenStatus == .waiting {
                Text(model.screenPending).foregroundStyle(.secondary)
            } else if !model.auto, model.greenScreenStatus == .notFound {
                Text("None found").foregroundStyle(.secondary)
            }
            Spacer()
            if model.auto {
                Text(model.screenFound).foregroundStyle(.secondary)
            } else {
                Picker("Screen", selection: Binding(get: { library.screen }, set: { model.setScreen($0) })) {
                    Text("Either").tag(ScreenColor.any)
                    Text("Green").tag(ScreenColor.green)
                    Text("Blue").tag(ScreenColor.blue)
                    Divider()
                    Text("Off").tag(ScreenColor.off)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .focusEffectDisabled()
                .fixedSize()
            }
        }

        Row(info: "Where the outline of you comes from. macOS is the matte its own Background effect uses: soft "
            + "hair, and it keeps what you hold. Vision is the public one, coarser."
            + (model.auto ? " Autocalibrate's picking it now, macOS whenever it works. Turn Autocalibrate off to "
               + "pick it yourself." : "")) {
            Text("Matting").foregroundStyle(model.auto ? .secondary : .primary)
            if model.auto || model.systemMatte, model.usingSystemMatte == false {
                Text("macOS's isn't working").foregroundStyle(.secondary)
            }
            Spacer()
            // Autocalibrate's pick is whichever is in use.
            Picker("Matting", selection: Binding(
                get: { model.auto ? model.usingSystemMatte ?? true : model.systemMatte },
                set: { model.setSystemMatte($0) })) {
                Text("macOS").tag(true)
                Text("Vision").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .focusEffectDisabled()
            .fixedSize()
            .disabled(model.auto)
        }
        tune("Detection", \.detection, "How sure the matte has to be that something's you. Lower keeps "
             + "borderline stuff like a chair back, higher trims it.")
        tune("Smoothing", \.smoothing, "Averages the matte over time where the picture's still, so borderline "
             + "spots stop flickering. 0 is off.")
        tune("Motion", \.motion, "How much a spot has to change to count as moving. Moving spots skip "
             + "smoothing, so lower trails less and higher calms more.")
        tune("Edge snap", \.refine, "How far Vision's coarse edge can move to land on a real edge in the picture. "
             + "macOS's matte doesn't need it. 0 is off.")
        tune("Edge softness", \.edgeSoftness, "How soft the matte's edge is. 0 is a hard cut-out, higher lets hair "
             + "fade the way it does in the picture.")
        tune("Room memory", \.roomMemory, "Learns what the empty room looks like, and keeps a spot that still "
             + "matches it as room when the matte isn't sure, like a chair. 0 is off.")
        tune("Room match", \.roomTolerance, "How close a spot's color has to be to the learned room to count as "
             + "it. Higher holds more, lower trusts the matte more.")
        tune("Edge detail", \.refineDetail, "How faint an edge the snap follows. Higher follows fainter edges, "
             + "and texture too.")
        if model.screenRGB != nil {
            tune("Key denoise", \.keyDenoise, "Reads each pixel's color from its neighbors, so noise doesn't make "
                 + "hair shimmer. Higher reaches further. 0 is off.")
            tune("Key smooth", \.keySmoothing, "Averages the key over time where the picture's still, against "
                 + "shimmer. 0 is off.")
            tune("Key edge", \.keyEdge, "Moves where the key cuts, from 50 in the middle. Up takes more away, "
                 + "down keeps more hair.")
            tune("Key softness", \.keySoftness, "How wide the fade from screen to you is. Wider is softer and "
                 + "calmer, narrower is crisper.")
            tune("Key method", \.keyLinear, "0 keys by how far a color is from the screen's, 100 by how much the "
                 + "screen's own channel stands out, which keeps wisps of hair. Between blends the two.")
            tune("Key hue", \.keyHue, "Turns the shade the key looks for, 50 being the one measured. Try it if "
                 + "part of the screen won't key out.")
            tune("Local color", \.localColor, "Keys against the screen's color right behind each spot, not one "
                 + "color for the whole screen. Helps with uneven light. 0 is off.")
            tune("Despill", \.despill, "Pulls green or blue bounce light out of skin and hair. Up to 50 is gentle, "
                 + "past it strong. 0 is off.")
        }
    }

    private func tune(_ title: String, _ path: WritableKeyPath<Tuning, Float>, _ tip: String) -> some View {
        let knob = Tuning.knob(path)
        let nudged = model.auto && knob.flatMap { model.offsets[$0.key] } != nil
        let steered = model.auto && !nudged && knob.map { AutoTune.steered.contains($0.key) } == true
        return TuneRow(title: title, value: Binding(get: { model.tuning[keyPath: path] }, set: { model.set(path, $0) }),
                       range: knob?.range ?? 0...1, nudged: nudged, steered: steered,
                       info: steered ? tip + " Autocalibrate's setting it now. Drag to lean it your way." : tip)
    }
}

/// A slider with its number beside it, so a value can be read off and reported.
private struct TuneRow: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    /// Leaned away from auto's pick, which the value's colour shows.
    let nudged: Bool
    /// Auto sets it from what it measures. Greyed, and still draggable to lean it.
    let steered: Bool
    let info: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1).frame(width: 96, alignment: .leading)
                .foregroundStyle(steered ? .secondary : .primary)
            // Named both ways: a nil tint doesn't take a slider's grey back off once it's been set.
            Slider(value: $value, in: range).controlSize(.small).tint(steered ? Color.gray : Color.accentColor)
            Text("\(Self.position(value, in: range))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(nudged ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 26, alignment: .trailing)
            InfoIcon(text: info)
        }
        .frame(minHeight: 24)
        .padding(.horizontal, 14)
    }

    /// Where the value sits along the slider, 0 to 100, whatever the knob's own units, so every row reads alike.
    static func position(_ value: Float, in range: ClosedRange<Float>) -> Int {
        let span = range.upperBound - range.lowerBound
        return Int((min(max((value - range.lowerBound) / span, 0), 1) * 100).rounded())
    }
}

/// The panel's empty spots, which move the window the way its title bar does. Tiles sit above and keep their own
/// drags, for reordering. Without the gesture only the title bar moves it.
private struct WindowDragArea: View {
    var body: some View {
        if #available(macOS 15, *) {
            Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture())
        } else {
            Color.clear
        }
    }
}

/// The title bar's green dot while an app reads the camera, as macOS marks its own camera in use.
struct LiveBadge: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            if model.live {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text("In use").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.trailing, 10)
        .frame(height: 28)
    }
}

/// A menu-style row that folds a section open and shut, its chevron turning down when open.
private struct DisclosureRow: View {
    let title: String
    @Binding var expanded: Bool
    @State private var hovering = false

    var body: some View {
        // No animation opening the section: the window grows in one step, and content sliding in meanwhile bounces
        // the tile grid. Only the chevron turns.
        Button { expanded.toggle() } label: {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: expanded)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.1) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}

/// A row that lights up on hover like a menu item.
private struct MenuRow: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
    }
}

/// A 16:9 tile: accent ring when active, a glyph for its kind, an X on hover when it can be deleted.
private struct Tile<Content: View>: View {
    var active: Bool
    var kind: ItemKind?
    var deletable = false
    var available = true
    var onDelete: () -> Void = {}
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    @State private var confirming = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08))
            content()
        }
        .frame(width: tileWidth, height: tileHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomLeading) {
            if let glyph = kind.flatMap(Self.glyph) {
                Image(systemName: glyph)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1.5)
                    .padding(5)
            }
        }
        .overlay(alignment: .topTrailing) {
            // The X asks first: it turns into a Delete button, and moving off the tile puts it back.
            if deletable, hovering {
                if confirming {
                    Button(action: onDelete) {
                        Text("Delete")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.red))
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .accessibilityLabel("Delete this background")
                } else {
                    Button { confirming = true } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .accessibilityLabel("Delete")
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                .opacity(active ? 1 : 0)
        }
        .opacity(available ? 1 : 0.35)
        .contentShape(Rectangle())
        .onHover {
            hovering = $0
            if !$0 { confirming = false }
        }
    }

    private static func glyph(_ kind: ItemKind) -> String? {
        switch kind {
        case .image: nil
        case .video: "play.fill"
        case .web: "globe"
        }
    }
}

private struct Thumbnail: View {
    let image: NSImage?
    let kind: ItemKind
    /// A video's moving thumbnail, set only while the window's on screen.
    var loop: URL?
    @StateObject private var player = LoopPlayer()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let frame = player.frame {
                Image(decorative: frame, scale: 2).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: tileWidth, height: tileHeight)
            } else if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: tileWidth, height: tileHeight)
            } else {
                Image(systemName: kind == .web ? "globe" : "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { player.play(reduceMotion ? nil : loop) }
        .onChange(of: loop) { _, url in player.play(reduceMotion ? nil : url) }
        .onChange(of: reduceMotion) { _, reduce in player.play(reduce ? nil : loop) }
        // No stop on disappear: a tile the grid moves can disappear after it reappears, which stopped its loop for
        // good. Hiding the window clears `loop`, and a deleted tile's player goes with it.
    }
}

/// Plays a video tile's loop through ImageIO's own animation, which decodes one small frame at a time on its own
/// schedule and hands each to the main thread.
@MainActor
private final class LoopPlayer: ObservableObject {
    @Published private(set) var frame: CGImage?
    private var url: URL?
    /// Bumped on every change, so a superseded animation stops at its next frame.
    private var generation = 0

    func play(_ url: URL?) {
        guard url != self.url else { return }
        self.url = url
        generation += 1
        frame = nil
        guard let url else { return }
        let mine = generation
        let options = [kCGImageAnimationDelayTime: 1 / Double(Importer.loopRate)] as CFDictionary
        CGAnimateImageAtURLWithBlock(url as CFURL, options) { [weak self] _, image, stop in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine else {
                    stop.pointee = true
                    return
                }
                self.frame = image
            }
        }
    }
}

/// A tile being dragged within the panel, and the gap it would land in, as an index into the library's items. Nothing
/// moves till the drop: moving tiles as the cursor passed them slid others under it, which moved them back.
@MainActor
private final class Reorder: ObservableObject {
    @Published var dragging: String?
    @Published private(set) var slot: Int?
    private var clearing: DispatchWorkItem?

    func point(at slot: Int?) {
        clearing?.cancel()
        if slot != self.slot { self.slot = slot }
    }

    /// Going from one drop target to the next is an exit and then an enter, so the mark only goes once nothing's
    /// been entered for a moment. A drag that leaves the window, or ends outside it, clears it the same way.
    func left() {
        clearing?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.slot = nil }
        clearing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func finish() {
        clearing?.cancel()
        (slot, dragging) = (nil, nil)
    }

    /// Where the dragged tile goes, or nil when that's where it already is.
    func destination(in items: [Item]) -> (id: String, index: Int)? {
        guard let dragging, let slot, let from = items.firstIndex(where: { $0.id == dragging }),
              slot != from, slot != from + 1 else { return nil }
        return (dragging, slot > from ? slot - 1 : slot)
    }

    func marks(before id: String, in items: [Item]) -> Bool {
        destination(in: items) != nil && items.firstIndex { $0.id == id } == slot
    }

    /// Only the last tile marks the gap after it. Every other gap is the next tile's "before".
    func marks(after id: String, in items: [Item]) -> Bool {
        destination(in: items) != nil && items.last?.id == id && slot == items.count
    }
}

/// The bar in the gap a dragged tile will land in.
private struct InsertionMark: View {
    var body: some View {
        Capsule().fill(Color.accentColor).frame(width: 3, height: tileHeight - 6)
    }
}

/// Points a dragged tile at a gap, and imports anything dropped from outside. Tiles take both, so a file dropped
/// onto a thumbnail imports rather than bouncing.
private struct TileDrop: DropDelegate {
    enum Target {
        /// Off is pinned, so a tile dragged onto it goes first.
        case off
        case item(String)
        /// The + tile, which means the end.
        case end
        /// Between tiles, which keeps the gap already marked so the mark holds still crossing it.
        case gap
        /// The rest of the panel: imports only.
        case panel
    }

    let target: Target
    let model: AppModel
    let reorder: Reorder

    /// Tiles carry a file or a link like any other drag, so the marker is what tells them apart. `reorder` says
    /// which tile it is, since the marker's own data only arrives asynchronously.
    @MainActor
    private func isTileDrag(_ info: DropInfo) -> Bool {
        reorder.dragging != nil && info.hasItemsConforming(to: [.fastbgTile])
    }

    /// Over a tile, the gap before it on its left half and after it on its right.
    @MainActor
    private func slot(_ info: DropInfo) -> Int? {
        let items = model.library.items
        switch target {
        case .off: return 0
        case .end: return items.count
        case .gap: return reorder.slot
        case .panel: return nil
        case .item(let id):
            guard let i = items.firstIndex(where: { $0.id == id }) else { return nil }
            return info.location.x < tileWidth / 2 ? i : i + 1
        }
    }

    @MainActor
    func dropEntered(info: DropInfo) {
        if isTileDrag(info) { reorder.point(at: slot(info)) }
    }

    @MainActor
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isTileDrag(info) else { return DropProposal(operation: .copy) }
        reorder.point(at: slot(info))
        return DropProposal(operation: .move)
    }

    @MainActor
    func dropExited(info: DropInfo) {
        if isTileDrag(info) { reorder.left() }
    }

    @MainActor
    func performDrop(info: DropInfo) -> Bool {
        if isTileDrag(info) {
            reorder.point(at: slot(info))
            let move = reorder.destination(in: model.library.items)
            // The tile lands and comes back to full strength in the one motion.
            withAnimation(.snappy(duration: 0.25)) {
                if let move { model.move(move.id, to: move.index) }
                reorder.finish()
            }
            return true
        }
        let providers = Providers(info.itemProviders(for: [.fileURL, .url, .plainText]))
        Task { @MainActor [model] in
            let payloads = await Importer.payloads(from: providers.items)
            guard !payloads.isEmpty else { return NSSound.beep() }
            model.importPayloads(payloads)
        }
        return true
    }
}

/// NSItemProvider isn't Sendable, and these are only read, on the main actor.
private struct Providers: @unchecked Sendable {
    let items: [NSItemProvider]
    init(_ items: [NSItemProvider]) { self.items = items }
}

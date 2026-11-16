import AppKit
import SwiftUI

// A small window that operates itself, standing in for an agent at work: before every
// action it tells iris where the action is, exactly as an agent would. It gives iris
// something to record on any machine, without touching the real pointer or keyboard.
//
//   iris-demo [--iris PATH] [--front] [--start-after SECONDS] [--think SECONDS] [--real-pointer]
//
// The script starts on SIGUSR1, or by itself after --start-after seconds.
//
// With --real-pointer it works the way computer use does instead: it moves the real pointer
// and clicks the controls with real mouse events (which needs the accessibility permission),
// then puts the pointer back. The window still never takes the keyboard.

struct Options {
    var iris: String?
    var front = false
    var startAfter: Double?
    /// Seconds between declaring an action and carrying it out, the way an agent thinks
    /// between its tool calls.
    var think = 0.0
    /// Click with real mouse events, as computer use does.
    var realPointer = false
}

func parseOptions() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--iris": if !arguments.isEmpty { options.iris = arguments.removeFirst() }
        case "--front": options.front = true
        case "--start-after": if !arguments.isEmpty { options.startAfter = Double(arguments.removeFirst()) }
        case "--think": if !arguments.isEmpty { options.think = Double(arguments.removeFirst()) ?? 0 }
        case "--real-pointer": options.realPointer = true
        default:
            FileHandle.standardError.write(Data("iris-demo: unknown option \(argument)\n".utf8))
            exit(2)
        }
    }
    return options
}

struct Item: Identifiable, Equatable {
    let id: Int
    var title: String
    var tag: String
    var done = false
}

@MainActor
final class Board: ObservableObject {
    @Published var items: [Item] = [
        Item(id: 1, title: "Record the onboarding flow", tag: "Video"),
        Item(id: 2, title: "Review zoom pacing with the team", tag: "Design"),
        Item(id: 3, title: "Write release notes for 1.0", tag: "Docs"),
        Item(id: 4, title: "Export GIFs for the README", tag: "Video"),
        Item(id: 5, title: "Publish the changelog", tag: "Docs", done: true),
    ]
    @Published var filter = "Inbox"
    @Published var composing = false
    @Published var draft = ""
    @Published var pressed: String?
    /// Frames of the controls in window points, origin top left.
    var frames: [String: CGRect] = [:]

    var visible: [Item] {
        switch filter {
        case "Done": return items.filter(\.done)
        case "Video": return items.filter { $0.tag == "Video" && !$0.done }
        default: return items.filter { !$0.done }
        }
    }

    /// What a click on the named control does.
    func act(_ name: String) {
        switch name {
        case "new":
            composing = true
        case "add":
            items.insert(Item(id: (items.map(\.id).max() ?? 0) + 1, title: draft, tag: "Video"), at: 0)
            composing = false
            draft = ""
        case "side-Inbox", "side-Video", "side-Done":
            filter = String(name.dropFirst(5))
        default:
            if name.hasPrefix("check-"), let id = Int(name.dropFirst(6)), let index = items.firstIndex(where: { $0.id == id }) {
                items[index].done.toggle()
            }
        }
    }

    /// A click on the named control: it gives way under the button, then does its work.
    func click(_ name: String) async {
        pressed = name
        try? await Task.sleep(nanoseconds: 120_000_000)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            pressed = nil
            act(name)
        }
    }
}

struct FrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func tracked(_ name: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: FrameKey.self, value: [name: proxy.frame(in: .global)])
        })
    }

    /// A tracked control that answers a real click as well.
    func control(_ name: String, _ board: Board) -> some View {
        tracked(name).contentShape(Rectangle()).onTapGesture { Task { await board.click(name) } }
    }
}

/// Lets a click reach its control although the window is not the key window.
final class FirstClickHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct SidebarRow: View {
    let name: String
    let symbol: String
    let count: Int
    @ObservedObject var board: Board

    var body: some View {
        let selected = board.filter == name
        HStack(spacing: 9) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(selected ? Color.white : Color.accentColor)
            Text(name).foregroundStyle(selected ? Color.white : Color.primary)
            Spacer()
            Text("\(count)").font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? Color.accentColor : (board.pressed == "side-\(name)" ? Color.primary.opacity(0.08) : Color.clear)))
        .control("side-\(name)", board)
    }
}

struct ItemRow: View {
    let item: Item
    @ObservedObject var board: Board

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 19))
                .foregroundStyle(item.done ? Color.green : Color.secondary.opacity(0.7))
                .scaleEffect(board.pressed == "check-\(item.id)" ? 0.82 : 1)
                .control("check-\(item.id)", board)
            Text(item.title)
                .font(.system(size: 14.5))
                .strikethrough(item.done, color: .secondary)
                .foregroundStyle(item.done ? Color.secondary : Color.primary)
            Spacer()
            Text(item.tag)
                .font(.system(size: 11.5, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07))
            .allowsHitTesting(false))
    }
}

struct BoardView: View {
    @ObservedObject var board: Board

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("LISTS").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.leading, 10).padding(.bottom, 4)
                SidebarRow(name: "Inbox", symbol: "tray", count: board.items.filter { !$0.done }.count, board: board)
                SidebarRow(name: "Video", symbol: "video", count: board.items.filter { $0.tag == "Video" && !$0.done }.count, board: board)
                SidebarRow(name: "Done", symbol: "checkmark.circle", count: board.items.filter(\.done).count, board: board)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 52).padding(.bottom, 14)
            .frame(width: 200)
            .background(Color.primary.opacity(0.035))

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(board.filter).font(.system(size: 24, weight: .bold))
                    Spacer()
                    Label("New task", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor))
                        .scaleEffect(board.pressed == "new" ? 0.94 : 1)
                        .control("new", board)
                }
                .padding(.bottom, 16)

                if board.composing {
                    HStack(spacing: 10) {
                        Image(systemName: "circle.dashed").font(.system(size: 19)).foregroundStyle(.secondary)
                        ZStack(alignment: .leading) {
                            if board.draft.isEmpty {
                                Text("What needs doing?").foregroundStyle(.tertiary)
                            }
                            HStack(spacing: 1) {
                                Text(board.draft)
                                Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 17)
                            }
                        }
                        .font(.system(size: 14.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tracked("field")
                        Text("Add")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.accentColor))
                            .scaleEffect(board.pressed == "add" ? 0.92 : 1)
                            .control("add", board)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5))
                    .padding(.bottom, 8)
                    .transition(.opacity)
                }

                VStack(spacing: 8) {
                    ForEach(board.visible) { item in
                        ItemRow(item: item, board: board)
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26).padding(.top, 46).padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onPreferenceChange(FrameKey.self) { frames in
            MainActor.assumeIsolated { board.frames = frames }
        }
    }
}

@MainActor
final class Script {
    let board: Board
    let options: Options
    var started = false
    weak var window: NSWindow?
    /// Where the real pointer was before the script borrowed it.
    private var parked: CGPoint?

    init(board: Board, options: Options) {
        self.board = board
        self.options = options
    }

    func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Runs iris with these arguments and waits for it.
    func iris(_ arguments: [String]) async {
        guard let iris = options.iris else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: iris)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume() }
        }
    }

    /// Tells iris where the next action is, in window points, and what to say about it.
    func declare(_ name: String, kind: String = "click", caption: String? = nil, extra: [String] = []) async {
        guard let frame = board.frames[name] else { return }
        var arguments = ["mark", "--space", "window", "--kind", kind, "--label", name]
        if kind == "click" {
            arguments += ["--x", "\(frame.midX)", "--y", "\(frame.midY)"]
        } else {
            arguments += ["--rect", "\(frame.minX),\(frame.minY),\(frame.width),\(frame.height)"]
        }
        if let caption { arguments += ["--caption", caption] }
        await iris(arguments + extra)
    }

    func click(_ name: String, caption: String? = nil) async {
        await declare(name, caption: caption)
        await pause(options.think)
        guard options.realPointer else { return await board.click(name) }
        guard let frame = board.frames[name], let window, let screen = NSScreen.screens.first else { return }
        // Window points, origin top left, to the global coordinates mouse events use.
        let point = CGPoint(x: window.frame.minX + frame.midX, y: screen.frame.height - window.frame.maxY + frame.midY)
        if parked == nil { parked = CGEvent(source: nil)?.location }
        // An agent's pointer does not travel: it is at the target all at once, then clicks.
        post(.mouseMoved, at: point)
        await pause(0.18)
        post(.leftMouseDown, at: point)
        await pause(0.07)
        post(.leftMouseUp, at: point)
        await pause(0.12)
    }

    private func post(_ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
        if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
        event.post(tap: .cghidEventTap)
    }

    func run() async {
        guard !started else { return }
        started = true
        await pause(0.4)
        await iris(["caption", "Driven by a script, not by the mouse"])
        await pause(2.6)
        await click("new", caption: "Start a new task")
        await pause(1.0)
        let text = "Ship the launch video"
        await declare("field", kind: "type", extra: ["--zoom", "2.2", "--hold", "\(Double(text.count) * 0.07 + 1.0)"])
        await pause(0.5 + options.think)
        for character in text {
            board.draft.append(character)
            await pause(0.07)
        }
        await pause(0.7)
        if options.realPointer {
            await click("add")
        } else {
            // A shortcut leaves nothing for iris to see, so it is declared like a click.
            await iris(["keys", "cmd+enter"])
            await pause(0.35 + options.think)
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { board.act("add") }
        }
        await pause(1.9)
        await click("check-2", caption: "Tick off what is finished")
        await pause(5.2)
        await click("side-Done", caption: "Finished tasks are kept here")
        await pause(3.0)
        if let parked { CGWarpMouseCursorPosition(parked) }
        guard board.filter == "Done", board.items.count == 6, board.items.filter(\.done).count == 2 else {
            FileHandle.standardError.write(Data("iris-demo: the clicks did not reach the window; real mouse events need the accessibility permission\n".utf8))
            exit(1)
        }
        print("done")
        fflush(stdout)
        await pause(0.4)
        exit(0)
    }
}

@MainActor
func launch() {
    let options = parseOptions()
    let app = NSApplication.shared
    // An accessory application opens its window without taking the keyboard from whoever is
    // working on the machine.
    app.setActivationPolicy(.accessory)

    let board = Board()
    let script = Script(board: board, options: options)
    let size = NSSize(width: 860, height: 560)
    let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
    let window: NSWindow
    if options.realPointer {
        // A panel of this kind takes clicks without making its application the active one.
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: style.union(.nonactivatingPanel),
                            backing: .buffered, defer: false)
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        window = panel
    } else {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
    }
    script.window = window
    window.title = "Iris Demo"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.contentView = FirstClickHost(rootView: BoardView(board: board).frame(width: size.width, height: size.height))
    if let screen = NSScreen.main {
        let area = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
    }
    if options.front || options.realPointer {
        // Real clicks land on whatever is on top, so the window has to be.
        window.orderFrontRegardless()
    } else {
        window.orderBack(nil)
    }

    signal(SIGUSR1, SIG_IGN)
    let trigger = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    trigger.setEventHandler { Task { @MainActor in await script.run() } }
    trigger.resume()
    if let delay = options.startAfter {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Task { @MainActor in await script.run() } }
    }
    print("ready \(ProcessInfo.processInfo.processIdentifier)")
    fflush(stdout)
    app.run()
}

MainActor.assumeIsolated { launch() }

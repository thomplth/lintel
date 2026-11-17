import AppKit

// Synthesises pointer input inside the test VM. Coordinates are AppKit screen points (origin bottom-left).
//   vm-input click X Y
//   vm-input drag FROM_X FROM_Y TO_X TO_Y [--hold SECONDS] [--command [--lead SECONDS]] [--back]
// --lead holds ⌘ that long before the press, for what appears only while ⌘ is down.

let arguments = Array(CommandLine.arguments.dropFirst())
let numbers = arguments.compactMap(Double.init)
let holdsCommand = arguments.contains("--command")
let returnsToStart = arguments.contains("--back")
let lead = arguments.firstIndex(of: "--lead").flatMap { Double(arguments[safe: $0 + 1] ?? "") } ?? 0
let hold = arguments.firstIndex(of: "--hold").flatMap { Double(arguments[safe: $0 + 1] ?? "") } ?? 0.3
let screenHeight = NSScreen.screens[0].frame.height
let source = CGEventSource(stateID: .hidSystemState)
let flags: CGEventFlags = holdsCommand ? .maskCommand : []

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: screenHeight - y) }

func post(_ type: CGEventType, at location: CGPoint) {
    let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: .left)
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
    usleep(20_000)
}

func postCommandKey(down: Bool) {
    let event = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: down)
    event?.flags = down ? .maskCommand : []
    event?.post(tap: .cghidEventTap)
    usleep(100_000)
}

func glide(from start: CGPoint, to end: CGPoint) {
    for step in 1...25 {
        let t = Double(step) / 25
        post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
    }
}

switch arguments.first {
case "click" where numbers.count >= 2:
    let location = point(numbers[0], numbers[1])
    post(.mouseMoved, at: location)
    post(.leftMouseDown, at: location)
    post(.leftMouseUp, at: location)
case "drag" where numbers.count >= 4:
    let start = point(numbers[0], numbers[1]), end = point(numbers[2], numbers[3])
    post(.mouseMoved, at: start)
    if holdsCommand { postCommandKey(down: true) }
    usleep(useconds_t(lead * 1_000_000))
    post(.leftMouseDown, at: start)
    glide(from: start, to: end)
    usleep(useconds_t(hold * 1_000_000))
    var release = end
    if returnsToStart {
        glide(from: end, to: start)
        release = start
    }
    post(.leftMouseUp, at: release)
    if holdsCommand { postCommandKey(down: false) }
default:
    FileHandle.standardError.write(Data("usage: vm-input click X Y | drag FX FY TX TY [--hold S] [--command [--lead S]] [--back]\n".utf8))
    exit(2)
}

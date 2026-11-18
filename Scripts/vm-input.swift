import AppKit

// Synthesises pointer input inside the test VM. Coordinates are AppKit screen points (origin bottom-left).
//   vm-input click X Y
//   vm-input drag FROM_X FROM_Y TO_X TO_Y [--hold SECONDS] [--command [--lead SECONDS]] [--back]
//   vm-input type TEXT          types into whatever has keyboard focus
//   vm-input key NAME [--command] [--control] [--option] [--shift]
//                               presses return, escape, up, down, left, right, tab, delete, space, a letter or digit
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

func press(_ virtualKey: CGKeyCode, text: String? = nil, modifiers: CGEventFlags = []) {
    for isDown in [true, false] {
        let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: isDown)
        event?.flags = modifiers
        if let text { event?.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16)) }
        event?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
}

let namedKeys: [String: CGKeyCode] = [
    "return": 0x24, "escape": 0x35, "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C, "tab": 0x30, "delete": 0x33,
    "space": 0x31, "comma": 0x2B, "slash": 0x2C,
    "a": 0x00, "b": 0x0B, "h": 0x04, "l": 0x25, "p": 0x23,
    "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A, "8": 0x1C, "9": 0x19,
]

let keyModifiers: CGEventFlags = [
    ("--command", CGEventFlags.maskCommand), ("--control", .maskControl), ("--option", .maskAlternate), ("--shift", .maskShift),
].reduce([]) { flags, entry in arguments.contains(entry.0) ? flags.union(entry.1) : flags }

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
case "type" where arguments.count >= 2:
    for character in arguments.dropFirst().joined(separator: " ") { press(0, text: String(character)) }
case "key" where namedKeys[arguments[safe: 1] ?? ""] != nil:
    press(namedKeys[arguments[1]]!, modifiers: keyModifiers)
default:
    FileHandle.standardError.write(Data("usage: vm-input click X Y | drag FX FY TX TY [--hold S] [--command [--lead S]] [--back] | type TEXT | key NAME [--command] [--control] [--option] [--shift]\n".utf8))
    exit(2)
}

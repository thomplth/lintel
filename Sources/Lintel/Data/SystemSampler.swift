import AudioToolbox
import CoreAudio
import CoreWLAN
import Foundation
import IOKit
import IOKit.ps
import LintelCore

/// Reads everything `host.system()`, `host.network()` and friends return. Snapshots are taken one at a time on their own
/// queue, since IOKit, CoreAudio and CoreWLAN reads can take tens of milliseconds; anything that spawns a tool runs on
/// a background queue and is merged into the next snapshot.
final class SystemSampler {
    struct Needs: Equatable {
        var network = false
        var disk = false
        var processes = false
        var audio = false
        var bluetooth = false

        init() {}

        init(sources: [String]) {
            let all = sources.joined(separator: "\n")
            network = all.contains("host.network")
            disk = all.contains("host.disk")
            processes = all.contains("host.processes")
            audio = all.contains("host.audio")
            bluetooth = all.contains("host.bluetooth")
        }
    }

    var needs: Needs {
        get { lock.withLock { wanted } }
        set { lock.withLock { wanted = newValue } }
    }
    /// The process list costs a `ps` run, so it is only kept fresh while a panel is there to show it.
    var isPanelOpen: Bool {
        get { lock.withLock { isPanelShown } }
        set { lock.withLock { isPanelShown = newValue } }
    }
    private var wanted = Needs()
    private var isPanelShown = false
    private let sampling = DispatchQueue(label: "lintel.sampler.snapshot", qos: .userInitiated)

    private var previousTicks: [(busy: UInt64, total: UInt64)] = []
    private var previousNetwork: (at: TimeInterval, received: UInt64, sent: UInt64)?
    private var previousDisk: (at: TimeInterval, read: UInt64, written: UInt64)?
    private var volumes: (at: TimeInterval, value: JSONValue)?
    private var wifi: (at: TimeInterval, value: JSONValue)?
    private let background = DispatchQueue(label: "lintel.sampler", qos: .utility)
    private let lock = NSLock()
    private var processes: JSONValue = .array([])
    private var bluetooth: JSONValue = ["on": false, "devices": []]
    private var isSamplingProcesses = false
    private var lastBluetoothSample: TimeInterval = -.infinity
    private var tick = 0

    func snapshot() -> JSONValue {
        sampling.sync { takeSnapshot() }
    }

    func snapshot(then completion: @escaping @MainActor (JSONValue) -> Void) {
        sampling.async {
            let data = Perf.measure("sampler.snapshot") { self.takeSnapshot() }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(data) } }
        }
    }

    private func takeSnapshot() -> JSONValue {
        let needs = needs
        let isPanelOpen = isPanelOpen
        let now = ProcessInfo.processInfo.systemUptime
        tick += 1
        var data: [String: JSONValue] = ["system": system(), "appearance": ["dark": .bool(Self.isDark)]]
        if needs.network { data["network"] = network(now: now) }
        if needs.disk { data["disk"] = disk(now: now) }
        if needs.audio { data["audio"] = Self.audio() }
        if needs.processes {
            if isPanelOpen, tick % 2 == 0 { sampleProcesses() }
            data["processes"] = lock.withLock { processes }
        }
        if needs.bluetooth {
            if now - lastBluetoothSample > 30 {
                lastBluetoothSample = now
                sampleBluetooth()
            }
            data["bluetooth"] = lock.withLock { bluetooth }
        }
        return .object(data)
    }

    private static var isDark: Bool {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String == "Dark"
    }

    // MARK: System

    private func system() -> JSONValue {
        let cores = coreLoads()
        let total = cores.isEmpty ? 0 : cores.reduce(0, +) / Double(cores.count)
        var averages = [Double](repeating: 0, count: 3)
        getloadavg(&averages, 3)
        let memory = memoryUsage()
        return [
            "cpu": .number(total),
            "cores": .array(cores.map(JSONValue.number)),
            "loadAverage": .array(averages.map(JSONValue.number)),
            "memoryUsed": .number(memory.used),
            "memoryTotal": .number(Double(ProcessInfo.processInfo.physicalMemory)),
            "memoryPressure": .number(memory.pressure),
            "swapUsed": .number(memory.swap),
            "gpu": gpuLoad().map(JSONValue.number) ?? .null,
            "uptime": .number(ProcessInfo.processInfo.systemUptime.rounded()),
            "thermal": .string(thermalName),
            "battery": battery(),
        ]
    }

    private var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "nominal"
        }
    }

    private func coreLoads() -> [Double] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info
        else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var ticks: [(busy: UInt64, total: UInt64)] = []
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            ticks.append((user + system + nice, user + system + nice + idle))
        }
        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else { return ticks.map { _ in 0 } }
        return zip(ticks, previousTicks).map { current, previous in
            current.total > previous.total
                ? min(max(Double(current.busy &- previous.busy) / Double(current.total &- previous.total), 0), 1) : 0
        }
    }

    private func memoryUsage() -> (used: Double, pressure: Double, swap: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var used = 0.0
        if status == KERN_SUCCESS {
            let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
            used = Double(pages) * Double(vm_kernel_page_size)
        }
        var level: Int32 = 100
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_level", &level, &levelSize, nil, 0)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)
        return (used, min(max(1 - Double(level) / 100, 0), 1), Double(swap.xsu_used))
    }

    private func gpuLoad() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var load: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let property = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue()
            // Undocumented key; absent on some GPUs and may change between macOS releases.
            if let statistics = property as? [String: Any], let percent = statistics["Device Utilization %"] as? Double {
                load = max(load ?? 0, percent / 100)
            }
        }
        return load
    }

    private func battery() -> JSONValue {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return .null }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let percent = description[kIOPSCurrentCapacityKey] as? Int
            else { continue }
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let isPlugged = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = description[isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int ?? -1
            let detail = batteryDetail()
            return [
                "percent": .number(Double(percent)),
                "charging": .bool(isCharging),
                "plugged": .bool(isPlugged),
                "minutesRemaining": minutes > 0 ? .number(Double(minutes)) : .null,
                "cycles": detail.cycles.map { .number(Double($0)) } ?? .null,
                "health": detail.health.map(JSONValue.number) ?? .null,
            ]
        }
        return .null
    }

    private func batteryDetail() -> (cycles: Int?, health: Double?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        func property(_ name: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        }
        let health: Double? = if let maximum = property("AppleRawMaxCapacity"), let design = property("DesignCapacity"), design > 0 {
            min(Double(maximum) / Double(design), 1)
        } else {
            nil
        }
        return (property("CycleCount"), health)
    }

    // MARK: Network

    private func network(now: TimeInterval) -> JSONValue {
        var received: UInt64 = 0, sent: UInt64 = 0
        var address: String?, interface: String?
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            defer { freeifaddrs(list) }
            for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let name = String(cString: entry.pointee.ifa_name)
                guard let socket = entry.pointee.ifa_addr, (entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
                if socket.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en"), let raw = entry.pointee.ifa_data {
                    let counters = raw.assumingMemoryBound(to: if_data.self).pointee
                    received += UInt64(counters.ifi_ibytes)
                    sent += UInt64(counters.ifi_obytes)
                } else if socket.pointee.sa_family == UInt8(AF_INET), address == nil, name.hasPrefix("en") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        address = String(cString: host)
                        interface = name
                    }
                }
            }
        }
        var down = 0.0, up = 0.0
        if let previous = previousNetwork, now > previous.at {
            // The kernel's per-interface byte counters are 32-bit and wrap; a wrapped interval reads as zero.
            if received >= previous.received { down = Double(received - previous.received) / (now - previous.at) }
            if sent >= previous.sent { up = Double(sent - previous.sent) / (now - previous.at) }
        }
        previousNetwork = (now, received, sent)

        if wifi == nil || now - wifi!.at > 5 {
            var value = JSONValue.null
            if let client = CWWiFiClient.shared().interface(), client.powerOn(), client.wlanChannel() != nil {
                value = [
                    "ssid": client.ssid().map(JSONValue.string) ?? .null,
                    "rssi": .number(Double(client.rssiValue())),
                    "channel": .number(Double(client.wlanChannel()?.channelNumber ?? 0)),
                ]
            }
            wifi = (now, value)
        }
        return [
            "down": .number(down), "up": .number(up),
            "interface": interface.map(JSONValue.string) ?? .null,
            "ip": address.map(JSONValue.string) ?? .null,
            "wifi": wifi?.value ?? .null,
        ]
    }

    // MARK: Disk

    private func disk(now: TimeInterval) -> JSONValue {
        if volumes == nil || now - volumes!.at > 15 {
            let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
            let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
            let entries: [JSONValue] = urls.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: Set(keys)), let total = values.volumeTotalCapacity, total > 0
                else { return nil }
                return [
                    "name": .string(values.volumeName ?? url.lastPathComponent),
                    "total": .number(Double(total)),
                    "free": .number(Double(values.volumeAvailableCapacityForImportantUsage ?? 0)),
                ]
            }
            volumes = (now, .array(entries))
        }

        var read: UInt64 = 0, written: UInt64 = 0
        var iterator: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS {
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                let property = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                guard let statistics = property as? [String: Any] else { continue }
                read += (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                written += (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
        }
        var readRate = 0.0, writeRate = 0.0
        if let previous = previousDisk, now > previous.at {
            if read >= previous.read { readRate = Double(read - previous.read) / (now - previous.at) }
            if written >= previous.written { writeRate = Double(written - previous.written) / (now - previous.at) }
        }
        previousDisk = (now, read, written)
        return ["volumes": volumes?.value ?? .array([]), "readRate": .number(readRate), "writeRate": .number(writeRate)]
    }

    // MARK: Processes

    func refreshProcesses(then completion: @escaping @MainActor () -> Void) {
        guard needs.processes else { return }
        sampleProcesses { DispatchQueue.main.async { MainActor.assumeIsolated(completion) } }
    }

    private func sampleProcesses(then completion: @escaping @Sendable () -> Void = {}) {
        guard !lock.withLock({ isSamplingProcesses }) else { return }
        lock.withLock { isSamplingProcesses = true }
        background.async { [self] in
            defer { completion() }
            let output = Shell.capture("/bin/ps", ["-Aceo", "pid=,pcpu=,rss=,comm=", "-r"])
            let entries: [JSONValue] = output.split(separator: "\n").prefix(10).compactMap { line in
                let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count == 4, let pid = Double(parts[0]), let cpu = Double(parts[1]), let rss = Double(parts[2])
                else { return nil }
                return ["pid": .number(pid), "cpu": .number(cpu / 100), "memory": .number(rss * 1024), "name": .string(String(parts[3]))]
            }
            lock.withLock {
                processes = .array(entries)
                isSamplingProcesses = false
            }
        }
    }

    // MARK: Bluetooth

    private func sampleBluetooth() {
        background.async { [self] in
            // system_profiler instead of IOBluetooth: the framework raises a Bluetooth privacy prompt just for listing.
            let output = Shell.capture("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
            guard let root = try? JSONValue.parse(output), let report = root["SPBluetoothDataType"].array?.first else { return }
            func devices(_ key: String, connected: Bool) -> [JSONValue] {
                (report[key].array ?? []).flatMap { entry -> [JSONValue] in
                    (entry.object ?? [:]).map { name, detail in
                        let levels = ["device_batteryLevelMain", "device_batteryLevel", "device_batteryLevelLeft", "device_batteryLevelCase"]
                        let level = levels.lazy.compactMap { detail[$0].string }.first
                            .flatMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
                        return ["name": .string(name), "connected": .bool(connected), "battery": level.map(JSONValue.number) ?? .null]
                    }
                }
            }
            let state: JSONValue = [
                "on": .bool(report["controller_properties"]["controller_state"].string == "attrib_on"),
                "devices": .array(devices("device_connected", connected: true) + devices("device_not_connected", connected: false)),
            ]
            lock.withLock { bluetooth = state }
        }
    }

    // MARK: Audio

    private static var defaultOutputDevice: AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain
    )

    static func audio() -> JSONValue {
        guard let device = defaultOutputDevice else { return ["volume": 0, "muted": false, "output": nil] }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &volume)
        var muted = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted)
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &size, &name)
        let output = name?.takeRetainedValue() as String?
        return ["volume": .number(Double(volume)), "muted": .bool(muted != 0), "output": output.map(JSONValue.string) ?? .null]
    }

    static func setVolume(_ fraction: Double) throws {
        guard let device = defaultOutputDevice else { throw ModuleFailure("there is no audio output device") }
        var volume = Float32(min(max(fraction, 0), 1))
        let status = AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        guard status == noErr else { throw ModuleFailure("this output device has no adjustable volume") }
    }

    static func setMuted(_ isMuted: Bool) throws {
        guard let device = defaultOutputDevice else { throw ModuleFailure("there is no audio output device") }
        var muted: UInt32 = isMuted ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muted)
        guard status == noErr else { throw ModuleFailure("this output device cannot be muted") }
    }
}

enum Shell {
    static func capture(_ tool: String, _ arguments: [String], input: String? = nil, timeout: TimeInterval = 20) -> String {
        (try? run(tool, arguments, input: input, timeout: timeout))?.stdout ?? ""
    }

    static func run(
        _ tool: String, _ arguments: [String], input: String? = nil, timeout: TimeInterval = 20,
        environment: [String: String]? = nil, directory: URL? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()

        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        var errors = Data()
        let errorReader = DispatchWorkItem { errors = stderr.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(execute: errorReader)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        errorReader.wait()
        process.waitUntilExit()
        deadline.cancel()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self))
    }
}

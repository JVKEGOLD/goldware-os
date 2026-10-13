import Foundation
import SMCKit

// GoldWare OS's fan helper. Installed by GoldWare OS as a LaunchDaemon (root) so the app can set fan
// speeds; it accepts only the fixed words in FanCommand from the one user named by --uid.
//   GoldWareFanHelper --uid 501 [--socket PATH] [--fake]
// --fake drives pretend fans (for tests) instead of the SMC.

var uid: uid_t = 0
var socketPath = FanHelper.socket
var fake = false
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--uid": uid = uid_t(it.next().flatMap { UInt32($0) } ?? 0)
    case "--socket": socketPath = it.next() ?? socketPath
    case "--fake": fake = true
    default: FileHandle.standardError.write(Data("unknown argument \(a)\n".utf8)); exit(2)
    }
}

final class FakeFans: FanHardware {
    var fans = [FanReading(actual: 1350, min: 1350, max: 5349, target: 1350, manual: false),
                FanReading(actual: 1350, min: 1350, max: 5777, target: 1350, manual: false)]
    func read() -> [FanReading] { fans }
    func setManual(_ i: Int, rpm: Double) -> Bool { fans[i].manual = true; fans[i].target = rpm; log("manual \(i) \(Int(rpm))"); return true }
    func setAuto(_ i: Int) -> Bool { fans[i].manual = false; log("auto \(i)"); return true }
    func log(_ s: String) { print(s); fflush(stdout) }
}

guard let hw: FanHardware = fake ? FakeFans() : SMCFans() else {
    FileHandle.standardError.write(Data("cannot open the SMC\n".utf8)); exit(1)
}
let state = FanState(hardware: hw, markerPath: fake ? nil : FanHelper.marker)
state.recoverIfNeeded()
let server = FanServer(state: state, socketPath: socketPath, allowedUID: uid)
do { try server.start() } catch { FileHandle.standardError.write(Data("cannot listen on \(socketPath): \(error)\n".utf8)); exit(1) }

// launchd stops us with SIGTERM: hand the fans back first.
signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
var sources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    s.setEventHandler { state.shutdown(); server.stop(); exit(0) }
    s.resume(); sources.append(s)
}
dispatchMain()

import SwiftUI
import Darwin

final class ProcessControlBlock {
    let pid: Int32
    let dylib: String
    let argv: [String]
    let home: String
    let ttyID: Int32
    let parentPID: Int32
    let startTime: Date
    var thread: pthread_t?
    var exitCode: Int32?

    init(pid: Int32, dylib: String, argv: [String], home: String, ttyID: Int32, parentPID: Int32) {
        self.pid = pid
        self.dylib = dylib
        self.argv = argv
        self.home = home
        self.ttyID = ttyID
        self.parentPID = parentPID
        self.startTime = Date()
    }
}

struct KernelProcessInfo {
    let pid: Int32
    let parentPID: Int32
    let ttyID: Int32
    let startTime: Date
    let argv: [String]

    var command: String {
        argv.first ?? ""
    }
}

final class ProcessBootInfo {
    let pcb: ProcessControlBlock

    init(pcb: ProcessControlBlock) {
        self.pcb = pcb
    }
}

struct ConsoleLine: Identifiable {
    let id: Int
    let content: AttributedString
}

struct UIOverlay: Identifiable {
    let id = UUID()
    let pid: Int32
    let overlayID: Int32   // process-facing id, for individual removal
    let object: AnyObject
    let frame: UIOverlayFrame
}

struct UIOverlayFrame {
    var x: Double
    var y: Double
    var width: Double?
    var height: Double?
    var isFullscreen: Bool
}

enum TTYStream {
    case stdout
    case stderr
    case system
    case panic
}

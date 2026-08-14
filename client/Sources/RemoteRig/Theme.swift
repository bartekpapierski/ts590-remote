import SwiftUI

// Theme for the dark operator console. The palette is fixed (not adaptive):
// the console reads like the rig's front panel regardless of system mode.
enum Theme {
    static let background = Color(red: 0.08, green: 0.09, blue: 0.11)
    static let bar = Color(red: 0.05, green: 0.06, blue: 0.08)
    static let panel = Color(red: 0.12, green: 0.13, blue: 0.16)
    static let panelEdge = Color.white.opacity(0.08)
    static let readout = Color(red: 0.92, green: 0.95, blue: 1.0)
    static let dim = Color.white.opacity(0.45)
    static let meter = Color(red: 0.2, green: 0.8, blue: 0.4)
    static let tx = Color(red: 0.9, green: 0.18, blue: 0.14)
    static let ok = Color(red: 0.25, green: 0.8, blue: 0.4)
    static let warn = Color.orange
}

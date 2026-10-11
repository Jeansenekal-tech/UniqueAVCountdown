import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            DisplaySettings().tabItem { Label("Display", systemImage: "display") }
            RemoteSettings().tabItem { Label("Remote", systemImage: "antenna.radiowaves.left.and.right") }
            MessageSettings().tabItem { Label("Messages", systemImage: "text.bubble") }
            UpdateSettings(updater: model.updater).tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 560, height: 520)
    }
}

private struct DisplaySettings: View {
    @EnvironmentObject var engine: TimerEngine

    var body: some View {
        Form {
            Section("Presenter screen shows") {
                Toggle("Segment title & speaker", isOn: $engine.settings.showTitle)
                Toggle("Time of day", isOn: $engine.settings.showClock)
                Toggle("Next segment", isOn: $engine.settings.showNext)
                Toggle("Progress bar", isOn: $engine.settings.showProgress)
                Toggle("24-hour clock", isOn: $engine.settings.clock24h)
                LabeledContent("Timer size") {
                    HStack {
                        Slider(value: $engine.settings.fontScale, in: 0.5...1.3)
                        Text("\(Int(engine.settings.fontScale * 100))%").monospacedDigit().frame(width: 44)
                    }
                }
            }
            Section("Behaviour") {
                Toggle("Count up in overtime (+00:12)", isOn: $engine.settings.overtimeCountUp)
                Toggle("Flash screen red in overtime", isOn: $engine.settings.flashOnOvertime)
                Toggle("Play sound at yellow / red warnings", isOn: $engine.settings.soundOnWarning)
                Toggle("Play sound at zero", isOn: $engine.settings.soundOnZero)
                Toggle("Keep running when pressing Next / Prev", isOn: $engine.settings.startOnNext)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RemoteSettings: View {
    @EnvironmentObject var engine: TimerEngine
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Phone / tablet remote (web)") {
                Toggle("Enable web remote", isOn: $engine.settings.webEnabled)
                portField("HTTP port", $engine.settings.webPort)
                ForEach(model.remoteURLs, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                Text("Open this address in Safari/Chrome on any phone on the same network.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("OSC (Companion, Stream Deck, TouchOSC, QLab)") {
                Toggle("Enable OSC", isOn: $engine.settings.oscEnabled)
                portField("UDP port", $engine.settings.oscPort)
                Text("/timer/start  /timer/pause  /timer/toggle  /timer/reset  /timer/next  /timer/prev\n/timer/add 60  /timer/sub 60  /timer/goto 3  /timer/message \"text\"  /timer/flash\n/timer/message/hide  /timer/blackout 1|0  /timer/quick 300\n/timer/video (PIP on/off)  /timer/layout (next)  /timer/layout 1–5")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("MIDI") {
                Toggle("Enable MIDI input", isOn: $engine.settings.midiEnabled)
                Picker("Channel", selection: $engine.settings.midiChannel) {
                    Text("Omni (all)").tag(0)
                    ForEach(1...16, id: \.self) { Text("Channel \($0)").tag($0) }
                }
                Stepper("First note: \(engine.settings.midiBaseNote) (\(noteName(engine.settings.midiBaseNote)))",
                        value: $engine.settings.midiBaseNote, in: 0...116)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(MIDIMap.commands.enumerated()), id: \.offset) { i, item in
                        let n = engine.settings.midiBaseNote + i
                        Text("Note/CC \(n) (\(noteName(n)))  →  \(item.label)")
                    }
                    Text("Program Change N  →  cue segment N+1")
                }
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func portField(_ title: String, _ value: Binding<Int>) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number.grouping(.never))
                .frame(width: 80).multilineTextAlignment(.trailing)
        }
    }

    private func noteName(_ n: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[((n % 12) + 12) % 12])\(n / 12 - 2)"
    }
}

private struct MessageSettings: View {
    @EnvironmentObject var engine: TimerEngine

    var body: some View {
        Form {
            Section {
                TextEditor(text: Binding(
                    get: { engine.settings.messagePresets.joined(separator: "\n") },
                    set: { engine.settings.messagePresets = $0.components(separatedBy: "\n") }
                ))
                .font(.body)
                .frame(minHeight: 260)
            } header: {
                Text("Quick message buttons (one per line)")
            } footer: {
                Text("These appear as one-click buttons in the operator window and on the phone remote.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct UpdateSettings: View {
    @EnvironmentObject var engine: TimerEngine
    @ObservedObject var updater: UpdateChecker

    var body: some View {
        Form {
            Section("Updates") {
                LabeledContent("This version", value: UpdateChecker.currentVersion)
                LabeledContent("Checks", value: UpdateChecker.repo.map { "github.com/\($0)" } ?? "Not set up")
                Toggle("Check for updates when the app opens", isOn: $engine.settings.checkUpdatesOnLaunch)
                HStack {
                    Button(updater.isChecking ? "Checking…" : "Check Now") { updater.checkNow() }
                        .disabled(updater.isChecking)
                    Text(updater.lastResult).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

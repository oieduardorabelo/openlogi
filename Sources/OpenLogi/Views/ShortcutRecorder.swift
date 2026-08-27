import SwiftUI

struct ShortcutRecorder: View {
    @Binding var stroke: KeyStroke
    @ObservedObject var engine: KeyboardEngine
    @State private var captureOwner = UUID()

    private var isRecording: Bool {
        engine.captureOwner == captureOwner
    }

    var body: some View {
        Button {
            if isRecording {
                engine.cancelCapture(owner: captureOwner)
            } else {
                engine.captureNext(owner: captureOwner) { captured in
                    stroke = captured.normalizedForInputMatching
                }
            }
        } label: {
            Text(isRecording ? "Press a key…" : stroke.displayName)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(minWidth: 112)
                .brandControlChrome()
        }
        .buttonStyle(.plain)
        .tint(isRecording ? .accentColor : nil)
        .disabled(engine.status != .running)
        .help(engine.status == .running ? "Record shortcut" : "Grant Accessibility access first")
        .onDisappear {
            engine.cancelCapture(owner: captureOwner)
        }
    }
}

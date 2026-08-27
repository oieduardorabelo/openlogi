import SwiftUI

struct RemapTargetPicker: View {
    @Binding var rule: ShortcutRule
    @ObservedObject var engine: KeyboardEngine
    @State private var captureOwner = UUID()

    private var isRecording: Bool {
        engine.captureOwner == captureOwner
    }

    var body: some View {
        Menu {
            Button {
                engine.captureNext(owner: captureOwner) { captured in
                    rule.output = captured
                    rule.systemAction = nil
                }
            } label: {
                Label("Record Keyboard Shortcut…", systemImage: "keyboard")
            }

            Divider()

            ForEach(SystemActionGroup.allCases) { group in
                Section(group.rawValue) {
                    ForEach(SystemAction.allCases.filter { $0.group == group }) { action in
                        Button {
                            engine.cancelCapture()
                            rule.systemAction = action
                        } label: {
                            Label(action.displayName, systemImage: action.symbolName)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let action = rule.systemAction {
                    Image(systemName: action.symbolName)
                }
                Text(isRecording ? "Press a key…" : rule.targetDisplayName)
                    .lineLimit(1)
            }
            .font(AppBrand.font(size: 13, weight: .semibold))
            .frame(minWidth: 150)
            .brandControlChrome()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(engine.status != .running)
        .help(engine.status == .running ? "Choose an action or keyboard shortcut" : "Grant Accessibility access first")
        .onDisappear {
            engine.cancelCapture(owner: captureOwner)
        }
    }
}

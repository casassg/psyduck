import SwiftUI

struct NewTaskSheet: View {
    @Bindable var viewModel: BoardViewModel
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("New Task")
                    .font(Theme.toolbarTitleFont)
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Button {
                    viewModel.showNewTaskSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .pointingHand()
            }
            .padding(20)

            Divider().opacity(0.15)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Title")
                        .font(Theme.filterFont)
                        .foregroundStyle(Theme.textSecondary)

                    TextField("What needs to be done?", text: $viewModel.newTaskTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.titleFont)
                        .focused($titleFocused)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Description")
                        .font(Theme.filterFont)
                        .foregroundStyle(Theme.textSecondary)

                    TextEditor(text: $viewModel.newTaskDescription)
                        .font(Theme.metaFont)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 100, maxHeight: 200)
                        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.cardBorder, lineWidth: 0.5)
                        )

                    Text("Markdown supported. This becomes the context for the planning agent.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(20)

            Divider().opacity(0.15)

            HStack {
                Spacer()
                Button("Cancel") {
                    viewModel.newTaskTitle = ""
                    viewModel.newTaskDescription = ""
                    viewModel.showNewTaskSheet = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)
                .pointingHand()

                Button {
                    viewModel.createManualTask()
                } label: {
                    Text("Create Task")
                        .font(Theme.filterFont)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Theme.triageAccent.opacity(0.8), in: Capsule())
                }
                .buttonStyle(.plain)
                .pointingHand()
                .disabled(viewModel.newTaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 460, maxWidth: 460, minHeight: 320, maxHeight: 420)
        .background(Theme.windowBackground)
        .onAppear { titleFocused = true }
    }
}

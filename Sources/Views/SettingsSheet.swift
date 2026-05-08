import SwiftUI

struct SettingsSheet: View {
    @Bindable var viewModel: BoardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Tracked Folders")
                    .font(Theme.toolbarTitleFont)
                    .foregroundStyle(Theme.textPrimary)

                Spacer()

                Button {
                    viewModel.showSettings = false
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

            // Description
            Text(
                "Add folders that contain your git repositories (e.g. ~/Development). The app will scan them for worktrees and match them to your PRs."
            )
            .font(Theme.metaFont)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Folder list
            if viewModel.trackedFolders.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.trackedFolders, id: \.self) { folder in
                            folderRow(folder)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }

            Divider().opacity(0.15)

            // Add folder button
            HStack {
                Spacer()
                Button {
                    pickFolder()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Add Folder")
                            .font(Theme.filterFont)
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.surfaceBackground, in: Capsule())
                    .overlay(Capsule().stroke(Theme.cardBorder, lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .pointingHand()
                Spacer()
            }
            .padding(16)
        }
        .frame(minWidth: 500, maxWidth: 500, minHeight: 300, maxHeight: 500)
        .background(Theme.windowBackground)
    }

    private func folderRow(_ folder: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inReviewAccent)

            Text(abbreviatePath(folder))
                .font(Theme.repoFont)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    viewModel.removeTrackedFolder(folder)
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.diffDeletion.opacity(0.7))
            }
            .buttonStyle(.plain)
            .pointingHand()
            .help("Remove folder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 28))
                .foregroundStyle(Theme.textTertiary)
            Text("No folders tracked yet")
                .font(Theme.filterFont)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing your git repositories"
        panel.prompt = "Track Folder"
        // Start in ~/Development if it exists
        let devPath = (NSHomeDirectory() as NSString).appendingPathComponent("Development")
        if FileManager.default.fileExists(atPath: devPath) {
            panel.directoryURL = URL(fileURLWithPath: devPath)
        }

        if panel.runModal() == .OK, let url = panel.url {
            withAnimation(.snappy(duration: 0.2)) {
                viewModel.addTrackedFolder(url.path)
            }
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

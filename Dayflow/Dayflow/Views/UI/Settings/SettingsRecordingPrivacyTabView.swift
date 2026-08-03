import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsRecordingPrivacyTabView: View {
  @ObservedObject var viewModel: RecordingPrivacySettingsViewModel
  @State private var isBlockedTrayTargeted = false

  private let gridColumns = [
    GridItem(.adaptive(minimum: 82, maximum: 96), spacing: 12, alignment: .top)
  ]

  var body: some View {
    SettingsSection(
      title: "Recording privacy",
      subtitle: "Choose apps Dayflow should hide from screenshots."
    ) {
      VStack(alignment: .leading, spacing: 18) {
        captureSourceControls
        Rectangle()
          .fill(SettingsStyle.divider)
          .frame(height: 1)
        searchField
        installedAppsGrid
          .frame(maxHeight: .infinity, alignment: .top)
        blockedAppsTray
      }
      .frame(maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxHeight: .infinity, alignment: .topLeading)
    .onAppear {
      viewModel.handleOnAppear()
    }
  }

  private var captureSourceControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Capture source")
            .font(.custom("Figtree", size: 13))
            .fontWeight(.semibold)
            .foregroundColor(SettingsStyle.text)
          Text("Choose the display, application, or window Dayflow samples locally.")
            .font(.custom("Figtree", size: 12))
            .foregroundColor(SettingsStyle.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 12)

        Picker(
          "Capture source",
          selection: Binding(
            get: { viewModel.selectedCaptureSource.id },
            set: { selectedID in
              guard let option = viewModel.captureOptions.first(where: { $0.id == selectedID })
              else { return }
              viewModel.selectCaptureSource(option)
            }
          )
        ) {
          ForEach(viewModel.captureOptions) { option in
            Text(option.label)
              .tag(option.id)
          }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 240, alignment: .trailing)
      }

      HStack(spacing: 10) {
        Image(systemName: "lock.shield")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(SettingsStyle.ink)

        if let selectedOption = viewModel.captureOptions.first(
          where: { $0.id == viewModel.selectedCaptureSource.id }
        ) {
          Text(selectedOption.detail ?? "Selected source is resolved when recording starts.")
            .font(.custom("Figtree", size: 12))
            .foregroundColor(SettingsStyle.secondary)
        } else {
          Text("Selected source is currently unavailable. Choose another source.")
            .font(.custom("Figtree", size: 12))
            .foregroundColor(SettingsStyle.destructive)
        }

        Spacer(minLength: 8)

        SettingsSecondaryButton(
          title: viewModel.isLoadingCaptureOptions ? "Loading..." : "Refresh",
          systemImage: "arrow.clockwise",
          isDisabled: viewModel.isLoadingCaptureOptions,
          action: viewModel.loadCaptureOptions
        )
      }

      if let error = viewModel.captureSourceError {
        Text(error)
          .font(.custom("Figtree", size: 12))
          .foregroundColor(SettingsStyle.destructive)
      }
    }
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(SettingsStyle.meta)

      TextField("Search installed apps", text: $viewModel.searchText)
        .textFieldStyle(.plain)
        .font(.custom("Figtree", size: 13))
        .foregroundColor(SettingsStyle.text)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.black.opacity(0.04))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(SettingsStyle.divider, lineWidth: 1)
    )
  }

  private var installedAppsGrid: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("Installed apps")
          .font(.custom("Figtree", size: 13))
          .fontWeight(.semibold)
          .foregroundColor(SettingsStyle.text)

        Spacer()

        if viewModel.isLoadingApplications {
          SettingsMetadata(text: "Loading apps...")
        } else {
          SettingsMetadata(text: "\(viewModel.filteredApplications.count) shown")
        }
      }

      if viewModel.isLoadingApplications && viewModel.installedApplications.isEmpty {
        ProgressView()
          .controlSize(.small)
          .padding(.vertical, 20)
          .frame(maxWidth: .infinity, alignment: .center)
      } else if viewModel.filteredApplications.isEmpty {
        Text("No apps match your search.")
          .font(.custom("Figtree", size: 13))
          .foregroundColor(SettingsStyle.secondary)
          .padding(.vertical, 20)
          .frame(maxWidth: .infinity, alignment: .center)
      } else {
        ScrollView(.vertical, showsIndicators: true) {
          LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
            ForEach(viewModel.filteredApplications) { app in
              RecordingPrivacyGridAppButton(
                app: app,
                isBlocked: viewModel.isBlocked(app)
              ) {
                viewModel.toggleBlocked(app)
              }
              .onDrag {
                NSItemProvider(object: app.bundleIdentifier as NSString)
              }
            }
          }
          .padding(8)
        }
        .frame(maxHeight: .infinity)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.black.opacity(0.025))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(SettingsStyle.divider, lineWidth: 1)
        )
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }

  private var blockedAppsTray: some View {
    VStack(alignment: .leading, spacing: 10) {
      Rectangle()
        .fill(SettingsStyle.divider)
        .frame(height: 1)

      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text("Blocked apps")
          .font(.custom("Figtree", size: 13))
          .fontWeight(.semibold)
          .foregroundColor(SettingsStyle.text)

        SettingsMetadata(text: "\(viewModel.blockedApplications.count) blocked")

        Spacer()

        SettingsSecondaryButton(
          title: "Clear",
          isDisabled: viewModel.blockedApplications.isEmpty,
          action: viewModel.clearBlockedApplications
        )
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          if viewModel.blockedApplications.isEmpty {
            Text("Drag apps here to hide them from recording")
              .font(.custom("Figtree", size: 13))
              .foregroundColor(SettingsStyle.meta)
              .frame(height: 58)
              .padding(.horizontal, 12)
          } else {
            ForEach(viewModel.blockedApplications) { app in
              RecordingPrivacyGridAppButton(
                app: app,
                isBlocked: true
              ) {
                viewModel.removeBlockedApplication(app)
              }
            }
          }
        }
        .frame(minHeight: 96, alignment: .leading)
      }
      .frame(maxWidth: .infinity)
      .padding(8)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.black.opacity(isBlockedTrayTargeted ? 0.08 : 0.035))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(
            isBlockedTrayTargeted ? SettingsStyle.ink.opacity(0.35) : SettingsStyle.divider,
            lineWidth: 1
          )
      )
      .onDrop(
        of: [UTType.text],
        isTargeted: $isBlockedTrayTargeted,
        perform: viewModel.handleApplicationDrop
      )
    }
  }
}

private struct RecordingPrivacyGridAppButton: View {
  let app: RecordingPrivacyApplication
  let isBlocked: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 7) {
        ZStack(alignment: .bottomTrailing) {
          RecordingPrivacyAppIcon(app: app, size: 44)

          if isBlocked {
            Image(systemName: "lock.fill")
              .font(.system(size: 9, weight: .bold))
              .foregroundColor(.white)
              .frame(width: 18, height: 18)
              .background(Circle().fill(SettingsStyle.ink))
              .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
              .offset(x: 4, y: 4)
          }
        }

        Text(app.name)
          .font(.custom("Figtree", size: 11))
          .fontWeight(.semibold)
          .foregroundColor(isBlocked ? SettingsStyle.ink : SettingsStyle.text)
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .frame(width: 76, height: 30, alignment: .top)
      }
      .frame(width: 82, height: 88, alignment: .top)
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isBlocked ? SettingsStyle.ink.opacity(0.08) : Color.clear)
      )
    }
    .buttonStyle(.plain)
    .pointingHandCursor()
  }
}

private struct RecordingPrivacyAppIcon: View {
  let app: RecordingPrivacyApplication
  let size: CGFloat

  var body: some View {
    Image(nsImage: icon)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: size, height: size)
  }

  private var icon: NSImage {
    if let appURL = app.appURL {
      return NSWorkspace.shared.icon(forFile: appURL.path)
    }
    return NSWorkspace.shared.icon(for: .applicationBundle)
  }
}

#Preview("Recording Privacy") {
  SettingsRecordingPrivacyTabView(viewModel: RecordingPrivacySettingsViewModel())
    .frame(width: 760, height: 820)
    .padding()
}

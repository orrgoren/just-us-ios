import PhotosUI
import SwiftUI
import UIKit

/// One rounded field. Plus opens the camera and the library. The arrow appears only with text.
struct ChatEntry: View {
  @Bindable var model: SessionModel
  @Binding var libraryItem: PhotosPickerItem?
  @Binding var showCamera: Bool
  @Environment(\.colorScheme) private var scheme
  @FocusState private var focused: Bool
  @State private var showAttach = false
  @State private var showLibrary = false

  var body: some View {
    HStack(alignment: .bottom, spacing: 8) {
      field
      if ChatComposer.showsSend(model.chatDraft) {
        sendButton
      }
    }
    .confirmationDialog(L10n.chatPhoto, isPresented: $showAttach, titleVisibility: .hidden) {
      Button(L10n.chatCamera) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        showCamera = true
      }
      Button(L10n.chatLibrary) { showLibrary = true }
        .accessibilityIdentifier(A11y.chatPhoto)
      if Launch.isUITest {
        Button(L10n.chatSamplePhoto) { model.stageChatPhoto(PhotoBytes.sample()) }
          .accessibilityIdentifier(A11y.chatSamplePhoto)
      }
    }
    .photosPicker(isPresented: $showLibrary, selection: $libraryItem, matching: .images)
  }

  private var field: some View {
    HStack(alignment: .bottom, spacing: 4) {
      Button {
        showAttach = true
      } label: {
        Image(systemName: "plus")
          .font(.title3)
          .foregroundStyle(Theme.ink(scheme))
          .frame(width: 36, height: 36)
      }
      .accessibilityIdentifier(A11y.chatAttach)
      .accessibilityLabel(L10n.chatAttach)
      TextField(L10n.chatField, text: $model.chatDraft, axis: .vertical)
        .lineLimit(1...5)
        .focused($focused)
        .font(Theme.body)
        .foregroundStyle(Theme.ink(scheme))
        .accessibilityIdentifier(A11y.chatField)
        .submitLabel(.send)
        .onSubmit(send)
    }
    .padding(.leading, 4)
    .padding(.trailing, 12)
    .padding(.vertical, 4)
    .background(fieldFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .accessibilityElement(children: .contain)
  }

  private var sendButton: some View {
    Button(action: send) {
      Image(systemName: "arrow.up")
        .font(.body.weight(.semibold))
        .foregroundStyle(sendInk)
        .frame(width: 36, height: 36)
        .background(sendFill, in: Circle())
    }
    .accessibilityIdentifier(A11y.chatSend)
    .accessibilityLabel(L10n.chatSend)
  }

  private var fieldFill: Color {
    scheme == .dark ? Theme.color(Palette.secondaryDark) : Theme.blush
  }

  private var sendFill: Color {
    scheme == .dark ? Theme.color(Palette.accentOnDark) : Theme.wine
  }

  private var sendInk: Color {
    scheme == .dark ? Theme.ink : Theme.canvas
  }

  private func send() {
    focused = true
    Task { await model.sendChat() }
  }
}

/// The screenshot observer is added once per viewer, even if the view appears again.
final class ScreenshotWatch {
  private var token: NSObjectProtocol?
  private let center: NotificationCenter
  private let name: Notification.Name
  private(set) var registrations = 0
  var onShot: (() -> Void)?

  init(
    center: NotificationCenter = .default,
    name: Notification.Name = UIApplication.userDidTakeScreenshotNotification
  ) {
    self.center = center
    self.name = name
  }

  func register() {
    guard token == nil else { return }
    registrations += 1
    token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
      self?.onShot?()
    }
  }

  func unregister() {
    guard let token else { return }
    center.removeObserver(token)
    self.token = nil
  }

  deinit {
    unregister()
  }
}

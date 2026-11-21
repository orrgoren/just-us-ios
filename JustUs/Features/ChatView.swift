import PhotosUI
import SwiftUI
import UIKit

struct ChatScreen: View {
  @Bindable var model: SessionModel
  @Environment(\.colorScheme) private var scheme
  @State private var libraryItem: PhotosPickerItem?
  @State private var showCamera = false
  @State private var viewerImage: UIImage?
  @State private var viewerFailed = false
  @State private var keptImages: [UUID: UIImage] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Space.stack) {
      Text(L10n.chatTitle).font(Theme.title).accessibilityIdentifier(A11y.chatRoot)
      HelperText(text: L10n.chatHelp)
      if let notice = model.chatKeyNotice {
        Text(notice)
          .font(Theme.body)
          .foregroundStyle(Theme.ink(scheme))
          .accessibilityIdentifier(A11y.chatKeyNotice)
      }
      thread
      if model.ritual?.partner != nil {
        composer
      }
    }
    .sheet(isPresented: viewerPresented) { viewer }
    .sheet(isPresented: $showCamera) { CameraCapture { model.stageChatPhoto($0) } }
    .onChange(of: libraryItem) { _, item in
      guard let item else { return }
      Task {
        if let data = try? await item.loadTransferable(type: Data.self) {
          model.stageChatPhoto(data)
        }
        libraryItem = nil
      }
    }
  }

  private var viewerPresented: Binding<Bool> {
    Binding(get: { model.openChatPhoto != nil }, set: { if $0 == false { closeViewer() } })
  }

  @ViewBuilder private var thread: some View {
    if model.ritual?.partner == nil {
      Text(L10n.chatWaiting)
    } else if model.messages.isEmpty {
      Text(L10n.chatEmpty)
    } else {
      ForEach(model.messages) { line in
        bubble(line)
      }
    }
  }

  @ViewBuilder private var composer: some View {
    if let _ = model.stagedChatJPEG {
      Text(L10n.chatPhotoChoice).font(Theme.body)
      Picker(L10n.chatPhotoChoice, selection: $model.chatRetention) {
        Text(L10n.chatViewOnce).tag(ChatRetention.viewOnce)
        Text(L10n.chatKeep).tag(ChatRetention.keep)
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier(A11y.chatViewOnce)
      Text(model.chatRetention == .viewOnce ? L10n.chatViewOnceHelp : L10n.chatKeepHelp)
        .font(Theme.body)
      WineButton(title: L10n.chatSend, identifier: A11y.chatSend, busy: model.activity == .sendChat, busyTitle: L10n.loading) {
        Task { await model.sendStagedPhoto() }
      }
    } else {
      LabeledField(title: L10n.chatField, text: $model.chatDraft, identifier: A11y.chatField, need: .labelOnly)
      WineButton(title: L10n.chatSend, identifier: A11y.chatSend, busy: model.activity == .sendChat, busyTitle: L10n.loading) {
        Task { await model.sendChat() }
      }
      PhotosPicker(selection: $libraryItem, matching: .images) { Text(L10n.chatLibrary) }
        .buttonStyle(JustButtonStyle(kind: .secondary))
        .accessibilityIdentifier(A11y.chatPhoto)
      if UIImagePickerController.isSourceTypeAvailable(.camera) {
        ActionButton(title: L10n.chatCamera) { showCamera = true }
      }
      if Launch.isUITest {
        ActionButton(title: L10n.chatSamplePhoto, identifier: A11y.chatSamplePhoto) {
          model.stageChatPhoto(PhotoBytes.sample())
        }
      }
    }
  }

  private func bubble(_ line: ChatLine) -> some View {
    HStack {
      if line.mine { Spacer(minLength: 48) }
      VStack(alignment: line.mine ? .trailing : .leading, spacing: 8) {
        if line.notice {
          Text(line.text)
            .font(Theme.body)
            .foregroundStyle(Theme.ink(scheme))
            .accessibilityIdentifier(A11y.chatScreenshot)
        } else {
          photoBody(line)
          if line.photo != .viewOnce && line.photo != .kept && line.text.isEmpty == false {
            Text(line.text)
              .font(Theme.body)
              .foregroundStyle(foreground(mine: line.mine))
          }
        }
        if line.photo == .kept {
          ActionButton(title: L10n.chatDeletePhoto, kind: .destructive) {
            Task { await model.deleteChatPhoto(line.id) }
          }
        }
      }
      .padding(12)
      .background(line.notice ? Color.clear : fill(mine: line.mine), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .accessibilityIdentifier(line.photo == .opened ? A11y.chatOpened : A11y.chatLine)
      if line.mine == false { Spacer(minLength: 48) }
    }
  }

  @ViewBuilder private func photoBody(_ line: ChatLine) -> some View {
    if line.photo == .kept {
      if let image = keptImage(line) {
        Image(uiImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 180)
          .accessibilityIdentifier(A11y.chatPhotoCard)
      }
      Color.clear.frame(width: 0, height: 0).task { await rememberKept(line) }
    } else if line.photo == .viewOnce {
      Button(L10n.chatPhotoTap) {
        model.openChatPhoto = line.id
        viewerFailed = false
        Task {
          viewerImage = await openedImage(line)
          viewerFailed = viewerImage == nil
        }
      }
      .accessibilityIdentifier(A11y.chatPhotoCard)
    }
  }

  private func keptImage(_ line: ChatLine) -> UIImage? {
    if let data = line.previewJPEG, let image = UIImage(data: data) { return image }
    return keptImages[line.id]
  }

  private func rememberKept(_ line: ChatLine) async {
    guard keptImages[line.id] == nil, line.previewJPEG == nil else { return }
    guard let data = try? await model.backend.chatPhoto(line.id), let image = UIImage(data: data) else { return }
    keptImages[line.id] = image
  }

  private var viewer: some View {
    ChatPhotoViewer(image: viewerImage, failed: viewerFailed, mine: viewingMine) {
      closeViewer()
    } onScreenshot: {
      Task { await model.noteScreenshot() }
    }
  }

  private var viewingMine: Bool {
    model.messages.first { $0.id == model.openChatPhoto }?.mine ?? true
  }

  private func openedImage(_ line: ChatLine) async -> UIImage? {
    guard let data = try? await model.backend.chatPhoto(line.id) else { return nil }
    return UIImage(data: data)
  }

  private func closeViewer() {
    let id = model.openChatPhoto
    let sawIt = viewerImage != nil
    viewerImage = nil
    viewerFailed = false
    guard let id, sawIt else {
      model.openChatPhoto = nil
      return
    }
    Task { await model.finishViewOnce(id) }
  }

  private func foreground(mine: Bool) -> Color {
    mine ? Theme.canvas : Theme.ink
  }

  private func fill(mine: Bool) -> Color {
    mine ? Theme.wine : Theme.blush
  }
}

struct ChatPhotoViewer: View {
  var image: UIImage?
  var failed: Bool
  var mine: Bool
  var onClose: () -> Void
  var onScreenshot: () -> Void
  @State private var captured = UIScreen.main.isCaptured

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      if captured {
        Text(L10n.chatPhotoHidden).foregroundStyle(.white).padding()
      } else if let image {
        Image(uiImage: image).resizable().scaledToFit().padding()
      } else if failed {
        Text(L10n.chatOpenFailed).foregroundStyle(.white).padding()
      } else {
        Text(L10n.loading).foregroundStyle(.white)
      }
      VStack {
        HStack {
          Spacer()
          Button(L10n.chatClose, action: onClose).padding().foregroundStyle(.white)
        }
        Spacer()
      }
    }
    .accessibilityIdentifier(A11y.chatViewer)
    .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
      captured = UIScreen.main.isCaptured
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
      if mine == false { onScreenshot() }
    }
  }
}

struct CameraCapture: UIViewControllerRepresentable {
  var onImage: (Data) -> Void
  @Environment(\.dismiss) private var dismiss

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    var parent: CameraCapture
    init(_ parent: CameraCapture) { self.parent = parent }

    func imagePickerController(
      _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
        parent.onImage(data)
      }
      parent.dismiss()
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      parent.dismiss()
    }
  }
}

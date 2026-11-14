import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

enum AppleNonce {
  static func raw() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let source = status == errSecSuccess ? bytes : (0..<32).map { _ in UInt8.random(in: 0...255) }
    return source.map { String(format: "%02x", $0) }.joined()
  }

  static func hashed(_ raw: String) -> String {
    SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

@MainActor
final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
  private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?
  private var controller: ASAuthorizationController?

  func start() async throws -> (token: String, nonce: String) {
    if Launch.isUITest {
      return ("uitest", "uitest")
    }
    let nonce = AppleNonce.raw()
    let request = ASAuthorizationAppleIDProvider().createRequest()
    request.requestedScopes = [.fullName, .email]
    request.nonce = AppleNonce.hashed(nonce)
    let controller = ASAuthorizationController(authorizationRequests: [request])
    self.controller = controller
    controller.delegate = self
    controller.presentationContextProvider = self
    let credential: ASAuthorizationAppleIDCredential = try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      controller.performRequests()
    }
    guard let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8) else {
      throw AppError.notAuthenticated
    }
    return (token, nonce)
  }

  func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
      continuation?.resume(throwing: AppError.notAuthenticated)
      continuation = nil
      return
    }
    continuation?.resume(returning: credential)
    continuation = nil
  }

  func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }

  func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
    return window ?? ASPresentationAnchor()
  }
}

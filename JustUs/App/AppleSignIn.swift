import AuthenticationServices
import CryptoKit
import Foundation
import os
import Security
import UIKit

final class AppleNonceBox {
  var raw = ""
}

enum AppleSignInFailure {
  static func isCancellation(_ error: Error) -> Bool {
    if let auth = error as? ASAuthorizationError {
      return auth.code == .canceled
    }
    let bridged = error as NSError
    return bridged.domain == ASAuthorizationError.errorDomain
      && bridged.code == ASAuthorizationError.Code.canceled.rawValue
  }

  static func message(for error: Error) -> String {
    let code = (error as? ASAuthorizationError)?.code.rawValue ?? (error as NSError).code
    return "Sign in with Apple failed (\(code)): \(error.localizedDescription)"
  }

  static func log(_ error: Error) {
    let code = (error as? ASAuthorizationError)?.code.rawValue ?? (error as NSError).code
    let description = error.localizedDescription
    os_log(
      "Sign in with Apple failed code=%{public}d %{public}@",
      log: OSLog(subsystem: "com.orrgoren.justus", category: "apple-sign-in"),
      type: .error,
      code,
      description as NSString
    )
  }
}

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
      throw ASAuthorizationError(.invalidResponse)
    }
    return (token, nonce)
  }

  func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
      continuation?.resume(throwing: ASAuthorizationError(.invalidResponse))
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

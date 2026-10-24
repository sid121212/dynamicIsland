// Verify an update archive with the public key embedded in the shipped app. No Keychain/private-key access.
import CryptoKit
import Foundation
if CommandLine.arguments.count != 4 {
    fputs("Usage: VerifyUpdate <archive.zip> <base64-signature> <base64-public-key>\n", stderr); exit(2)
}
do {
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let signature = Data(base64Encoded: CommandLine.arguments[2]), let keyData = Data(base64Encoded: CommandLine.arguments[3]) else { exit(2) }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    guard key.isValidSignature(signature, for: archive) else { fputs("Invalid update signature\n", stderr); exit(1) }
    print("EdDSA signature verified against the shipped public key.")
} catch { fputs("Update verification failed: \(error)\n", stderr); exit(1) }

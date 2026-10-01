// Signs release downloads with the UPDATE_SIGNING_KEY environment variable.
//   swift scripts/sign-update.swift --public-key   prints the matching public key for build.sh
//   swift scripts/sign-update.swift Speck.zip      writes Speck.zip.sig
import CryptoKit
import Foundation

let env = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"] ?? ""
guard let raw = Data(base64Encoded: env.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    FileHandle.standardError.write(Data("UPDATE_SIGNING_KEY is missing or invalid. Make one with scripts/update-key.swift.\n".utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
if args.first == "--public-key" {
    print(key.publicKey.rawRepresentation.base64EncodedString())
} else if let path = args.first {
    let url = URL(fileURLWithPath: path)
    let signature = try key.signature(for: Data(contentsOf: url))
    try Data((signature.base64EncodedString() + "\n").utf8).write(to: url.appendingPathExtension("sig"))
} else {
    FileHandle.standardError.write(Data("Usage: sign-update.swift --public-key | <file>\n".utf8))
    exit(1)
}

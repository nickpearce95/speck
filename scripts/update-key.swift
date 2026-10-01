// Makes a new key for signing updates and prints it (base64 Ed25519 private key).
// Usage: swift scripts/update-key.swift | pbcopy
// then paste it as the UPDATE_SIGNING_KEY secret (repo Settings → Secrets and variables → Actions).
import CryptoKit

print(Curve25519.Signing.PrivateKey().rawRepresentation.base64EncodedString())

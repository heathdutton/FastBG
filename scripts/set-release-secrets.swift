// Loads the release workflow's secrets into this repo's release environment: the team's Developer ID Application and
// Apple Development identities from the login keychain, the app's Developer ID provisioning profile, and an App Store
// Connect API key. The .p12 gets a random passphrase, and everything goes to `gh secret set` on stdin, so no secret
// touches disk or argv. macOS asks once to allow the export.
//   swift scripts/set-release-secrets.swift --list                                   what it would send
//   swift scripts/set-release-secrets.swift --profile                                the profile alone
//   swift scripts/set-release-secrets.swift ~/Downloads/AuthKey_<key id>.p8 <issuer id>
// The key's ID comes from its file name. The issuer ID is on the same App Store Connect page, and like the key ID it
// names the key without granting anything.
import Foundation
import Security

func fail(_ message: String) -> Never {
    fputs("set-release-secrets: \(message)\n", stderr)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
let listOnly = args == ["--list"], profileOnly = args == ["--profile"]
guard listOnly || profileOnly || args.count == 2 else {
    fail("usage: set-release-secrets.swift --list | --profile | <AuthKey_ID.p8> <issuer id>")
}
let bundleID = "com.heathdutton.fastbg"

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let xcconfig = (try? String(contentsOf: repo.appendingPathComponent("Signing.xcconfig"), encoding: .utf8)) ?? ""
guard let team = xcconfig.firstMatch(of: #/DEVELOPMENT_TEAM *= *([A-Z0-9]{10})/#)?.1 else {
    fail("no team ID in Signing.xcconfig")
}

/// The newest identity whose certificate is named `prefix`, for the team where the name carries it.
func identity(_ prefix: String, team: Substring?) -> (SecIdentity, String)? {
    let query: [CFString: Any] = [kSecClass: kSecClassIdentity, kSecMatchLimit: kSecMatchLimitAll,
                                  kSecReturnRef: true]
    var found: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess,
          let all = found as? [SecIdentity] else { return nil }
    var best: (SecIdentity, String, Date)?
    for id in all {
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(id, &cert) == errSecSuccess, let cert,
              let name = SecCertificateCopySubjectSummary(cert) as String?, name.hasPrefix(prefix),
              team.map({ name.hasSuffix("(\($0))") }) ?? true,
              let expires = SecCertificateCopyNotValidAfterDate(cert) as Date?, expires > Date() else { continue }
        if best == nil || expires > best!.2 { best = (id, name, expires) }
    }
    return best.map { ($0.0, $0.1) }
}

/// The newest Developer ID profile for the app among those Xcode saved. Xcode makes it on the first Developer ID export
/// from a Mac signed in to the team, and the API key can't fetch it.
func directProfile() -> (Data, String)? {
    let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles")
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    var best: (Data, String, Date)?
    for file in files where file.pathExtension == "provisionprofile" {
        let decode = Process()
        decode.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        decode.arguments = ["cms", "-D", "-i", file.path]
        let out = Pipe()
        decode.standardOutput = out
        decode.standardError = FileHandle.nullDevice
        guard (try? decode.run()) != nil else { continue }
        let plist = out.fileHandleForReading.readDataToEndOfFile()
        decode.waitUntilExit()
        guard let info = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              info["ProvisionsAllDevices"] as? Bool == true,
              let entitlements = info["Entitlements"] as? [String: Any],
              entitlements["com.apple.application-identifier"] as? String == "\(team).\(bundleID)",
              let expires = info["ExpirationDate"] as? Date, expires > Date(),
              let name = info["Name"] as? String, let data = try? Data(contentsOf: file) else { continue }
        if best == nil || expires > best!.2 { best = (data, name, expires) }
    }
    return best.map { ($0.0, $0.1) }
}

guard let profile = directProfile() else {
    fail("no Developer ID profile for \(bundleID): export once with Xcode signed in to the team, as release.sh does")
}
print("profile: \(profile.1)")

/// One secret, its value on `gh`'s stdin.
func set(_ name: String, _ value: Data) {
    let gh = Process()
    gh.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    gh.arguments = ["gh", "secret", "set", name, "--env", "release"]
    gh.currentDirectoryURL = repo
    let input = Pipe()
    gh.standardInput = input
    do { try gh.run() } catch { fail("can't run gh: \(error)") }
    input.fileHandleForWriting.write(value)
    try? input.fileHandleForWriting.close()
    gh.waitUntilExit()
    guard gh.terminationStatus == 0 else { fail("gh couldn't set \(name)") }
}

if profileOnly {
    set("FASTBG_PROFILE_BASE64", Data(profile.0.base64EncodedString().utf8))
    print("release secret set: the profile")
    exit(0)
}

guard let developerID = identity("Developer ID Application:", team: team) else {
    fail("no Developer ID Application certificate for team \(team) in the keychain")
}
guard let development = identity("Apple Development:", team: nil) else {
    fail("no Apple Development certificate in the keychain")
}
// Names carry the account holder's name, so only the kind and ID after it are shown.
for (_, name) in [developerID, development] {
    print("identity: \(name.prefix { $0 != ":" }) (\(name.split(separator: "(").last ?? "")")
}
if listOnly { exit(0) }

let keyFile = URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath)
guard let keyID = keyFile.lastPathComponent.firstMatch(of: #/^AuthKey_([A-Z0-9]+)\.p8$/#)?.1 else {
    fail("the key file should be named AuthKey_<key id>.p8, as App Store Connect downloads it")
}
guard let p8 = try? Data(contentsOf: keyFile) else { fail("can't read \(keyFile.path)") }
let issuer = args[1]
guard issuer.wholeMatch(of: #/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/#) != nil else {
    fail("the issuer ID is the UUID above the keys table in App Store Connect")
}

var bytes = [UInt8](repeating: 0, count: 24)
guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { fail("no randomness") }
let passphrase = Data(bytes).base64EncodedString()
var params = SecItemImportExportKeyParameters()
params.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
params.passphrase = Unmanaged.passUnretained(passphrase as CFString)
var exported: CFData?
let status = SecItemExport([developerID.0, development.0] as CFArray, .formatPKCS12, [], &params, &exported)
guard status == errSecSuccess, let p12 = exported as Data? else {
    fail("export refused: \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")")
}

set("FASTBG_P12_BASE64", Data(p12.base64EncodedString().utf8))
set("FASTBG_P12_PASSWORD", Data(passphrase.utf8))
set("FASTBG_PROFILE_BASE64", Data(profile.0.base64EncodedString().utf8))
set("FASTBG_ASC_KEY_P8", p8)
set("FASTBG_ASC_KEY_ID", Data(keyID.utf8))
set("FASTBG_ASC_ISSUER", Data(issuer.utf8))
print("release secrets set: both identities, the profile, the API key \(keyID), and its issuer")

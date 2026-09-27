// Imports a .p12's signing identities into a keychain, where codesign can use them without a prompt. The passphrase
// comes from the environment, because `security import -P` would put it in argv for every process to read.
//   FASTBG_P12=<file> FASTBG_P12_PASSWORD=<passphrase> swift scripts/import-identity.swift <keychain>
import Foundation
import Security

let env = ProcessInfo.processInfo.environment
guard CommandLine.arguments.count == 2, let path = env["FASTBG_P12"],
      let p12 = FileManager.default.contents(atPath: path) else {
    fputs("usage: FASTBG_P12=<file> FASTBG_P12_PASSWORD=<passphrase> import-identity.swift <keychain>\n", stderr)
    exit(2)
}

func check(_ status: OSStatus, _ what: String) {
    guard status != errSecSuccess else { return }
    let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
    fputs("import-identity: \(what): \(reason)\n", stderr)
    exit(1)
}

var keychain: SecKeychain?
check(SecKeychainOpen(CommandLine.arguments[1], &keychain), "opening the keychain")
var codesign: SecTrustedApplication?
check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &codesign), "finding codesign")
var access: SecAccess?
check(SecAccessCreate("FastBG signing" as CFString, [codesign!] as CFArray, &access), "setting access")
var items: CFArray?
let options: [CFString: Any] = [kSecImportExportPassphrase: env["FASTBG_P12_PASSWORD"] ?? "",
                                kSecImportExportKeychain: keychain!, kSecImportExportAccess: access!]
check(SecPKCS12Import(p12 as CFData, options as CFDictionary, &items), "importing the .p12")
print("imported \((items as? [Any])?.count ?? 0) signing identities")

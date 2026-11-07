import Foundation
import MaschineryCore
import Darwin

// No caller-selected paths or commands are accepted by the administrator setup tool.
do {
    guard CommandLine.arguments.count == 2 else { throw MaschineryError.invalid("Expected a package setup operation") }
    if CommandLine.arguments[1] == "check" {
        try await XPCPrivilegedService().installationHealthCheck()
    } else {
        try HelperSetupInstaller().execute(CommandLine.arguments[1])
    }
} catch {
    fputs("Maschinery setup: \(error.localizedDescription)\n", stderr)
    exit(1)
}

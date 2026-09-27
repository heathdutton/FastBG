import CoreMediaIO
import Foundation

let relay = Relay()
CMIOExtensionProvider.startService(provider: relay.provider)
CFRunLoopRun()

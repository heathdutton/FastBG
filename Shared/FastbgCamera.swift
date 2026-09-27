import CoreVideo
import Foundation

/// The contract between the app and the camera extension. Both targets compile this file.
enum FastbgCamera {
    static let name = "FastBG"

    static let deviceID = UUID(uuidString: "DA0AA80A-3B1B-44DC-AF50-C48FDDC6B69B")!
    static let sourceStreamID = UUID(uuidString: "5AF9CE8C-201B-45DE-9942-372398753B91")!
    static let sinkStreamID = UUID(uuidString: "70995A80-3CA4-4B91-B3CB-AD9F729B0C01")!
    /// The extension passes this as legacyDeviceID, so it's the CMIO device UID and the `AVCaptureDevice.uniqueID`
    /// video apps see. The app uses it to find the sink and to keep fastbg out of its own camera list.
    static var deviceUID: String { deviceID.uuidString }

    static let width: Int32 = 1920
    static let height: Int32 = 1080
    static let fps: Int32 = 30
    /// 10-bit packed RGB, not BGRA: macOS only runs its own Background effect on a short list of formats, and BGRA
    /// is on it, so every app reading the camera would offer a second background on top of FastBG's. This one's off
    /// the list, the same 32 bits a pixel, and IOSurface-backed, which RGBA can't be. Apps asking for another
    /// format, as Chrome always does, get it converted by AVFoundation.
    static let pixelFormat: OSType = kCVPixelFormatType_ARGB2101010LEPacked

    /// How many clients stream from the source stream, published by the extension as a custom CMIO property on the
    /// source stream and the device. The value is a decimal NSString, the type custom properties are documented
    /// to carry, which the DAL hands back as a +1 CFString.
    static let readersProperty = "4cc_rdrs_glob_0000"
    static let readersSelector: FourCharCode = 0x7264_7273  // 'rdrs'

    /// Only a client signed with this identifier may start the sink stream.
    static let appSigningID = "com.heathdutton.fastbg"
    static let extensionBundleID = "com.heathdutton.fastbg.camera"
}

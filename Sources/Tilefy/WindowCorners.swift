import AppKit
import TilefyCore

/// Reads a window's real corner radius from the window server. It varies with the macOS version and
/// the kind of window, and there's no public API for another app's windows. This is private, so it's
/// looked up at runtime, and if it's ever missing Tilefy falls back to the system's usual radius.
enum WindowCorners {
    private struct API {
        let connection: @convention(c) () -> Int32
        let query: @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
        let copyWindows: @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
        let advance: @convention(c) (CFTypeRef) -> Bool
        let radii: @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    }

    private static let api: API? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: type) }
        }
        guard let connection = symbol("SLSMainConnectionID", as: (@convention(c) () -> Int32).self),
              let query = symbol("SLSWindowQueryWindows", as: (@convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?).self),
              let copyWindows = symbol("SLSWindowQueryResultCopyWindows", as: (@convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?).self),
              let advance = symbol("SLSWindowIteratorAdvance", as: (@convention(c) (CFTypeRef) -> Bool).self),
              let radii = symbol("SLSWindowIteratorGetResolvedCornerRadii", as: (@convention(c) (CFTypeRef) -> Unmanaged<CFArray>?).self)
        else { return nil }
        return API(connection: connection, query: query, copyWindows: copyWindows, advance: advance, radii: radii)
    }()

    /// The usual radius for a titled window, for when the real one can't be read.
    private static var systemDefault: CGFloat {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) ? 16 : 10
    }

    static func radius(of id: WindowID) -> CGFloat {
        guard let api,
              let query = api.query(api.connection(), [NSNumber(value: id)] as CFArray, 0)?.takeRetainedValue(),
              let iterator = api.copyWindows(query)?.takeRetainedValue(),
              api.advance(iterator),
              let radii = api.radii(iterator)?.takeRetainedValue() as? [NSNumber],
              let largest = radii.map(\.doubleValue).max()
        else { return systemDefault }
        return CGFloat(largest)
    }
}

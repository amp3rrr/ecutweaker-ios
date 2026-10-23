import Foundation

/// A byte pipe to an ELM327-compatible adapter (BLE, MFi/External Accessory, Wi-Fi TCP…).
/// Implementations may call the closures on any thread.
public protocol ElmLink: AnyObject {
    /// Human readable device name, shown in the log.
    var displayName: String { get }
    /// Opens the connection; `completion(nil)` when bytes can flow.
    func open(completion: @escaping (Error?) -> Void)
    func close()
    func send(_ data: Data)
    var onReceive: ((Data) -> Void)? { get set }
    /// Called when the link drops after a successful open.
    var onClosed: ((Error?) -> Void)? { get set }
}

public struct ElmLinkError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

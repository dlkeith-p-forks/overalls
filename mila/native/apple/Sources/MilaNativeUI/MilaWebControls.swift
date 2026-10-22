import Foundation
import SwiftUI

/// A validated HTTPS endpoint exposed by a machine's web control.
public struct MilaWebEndpoint: Equatable, Sendable {
    public let url: URL
    public init(_ value: String) throws {
        guard let parsed = URL(string: value), parsed.scheme?.lowercased() == "https",
              parsed.user == nil, parsed.password == nil, parsed.fragment == nil,
              parsed.host != nil else { throw MilaWebEndpointError.invalid }
        self.url = parsed
    }
}

public enum MilaWebEndpointError: Error, Equatable, Sendable { case invalid }

@MainActor public final class MilaWebControlsController: ObservableObject {
    @Published public private(set) var endpoint: MilaWebEndpoint?
    @Published public private(set) var error: MilaWebEndpointError?
    public init() {}
    @discardableResult public func set(_ value: String) -> Bool {
        do { endpoint = try MilaWebEndpoint(value); error = nil; return true }
        catch { endpoint = nil; error = .invalid; return false }
    }
    public func clear() { endpoint = nil; error = nil }
}

#if canImport(WebKit)
import WebKit

/// Native embedded web controls for iOS and macOS. Navigation remains HTTPS-only.
public struct MilaWebView: View {
    public let endpoint: MilaWebEndpoint
    public init(endpoint: MilaWebEndpoint) { self.endpoint = endpoint }
    public var body: some View { MilaWebViewRepresentable(url: endpoint.url) }
}

#if os(iOS)
struct MilaWebViewRepresentable: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView { WKWebView(frame: .zero) }
    func updateUIView(_ view: WKWebView, context: Context) { view.load(URLRequest(url: url)) }
}
#elseif os(macOS)
struct MilaWebViewRepresentable: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView { WKWebView(frame: .zero) }
    func updateNSView(_ view: WKWebView, context: Context) { view.load(URLRequest(url: url)) }
}
#endif
#endif

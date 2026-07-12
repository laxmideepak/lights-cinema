@preconcurrency import Foundation

@MainActor
final class NanoleafDiscoveryService: NSObject {
    private var browser: NetServiceBrowser?
    private var continuation: CheckedContinuation<[NanoleafDevice], Never>?
    private var devices = [String: NanoleafDevice]()

    func discover() async -> [NanoleafDevice] {
        guard continuation == nil else { return [] }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            devices.removeAll()
            let browser = NetServiceBrowser()
            browser.delegate = self
            self.browser = browser
            browser.searchForServices(ofType: "_nanoleafapi._tcp.", inDomain: "local.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finish() }
        }
    }

    private func discovered(_ service: NetService) {
        service.delegate = self
        service.resolve(withTimeout: 2)
    }

    private func resolved(_ sender: NetService) {
        guard let host = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")), sender.port > 0 else { return }
        devices[sender.name] = NanoleafDevice(id: sender.name, host: host, port: sender.port)
    }

    private func finish() {
        guard let continuation else { return }
        browser?.stop()
        browser = nil
        self.continuation = nil
        continuation.resume(returning: devices.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending })
    }
}

extension NanoleafDiscoveryService: @preconcurrency NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        discovered(service)
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) { finish() }
}

extension NanoleafDiscoveryService: @preconcurrency NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) { resolved(sender) }
}

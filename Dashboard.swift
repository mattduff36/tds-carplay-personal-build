import CallKit
import SwiftUI
import Swifter

final class DashboardHost: NSObject, ObservableObject, CXCallObserverDelegate {
    static let shared = DashboardHost()
    @Published private(set) var addresses: [String] = []
    @Published private(set) var message = ""
    @Published private(set) var running = false
    private var server: HttpServer?
    private var observer: CXCallObserver?
    private let lock = NSLock()
    private var phase = "idle"

    func refresh() {
        guard let observer = observer else { return }
        let calls = observer.calls.filter { !$0.hasEnded }
        let next: String
        if calls.contains(where: { !$0.isOutgoing && !$0.hasConnected }) {
            next = "incoming"
        } else if calls.contains(where: { $0.hasConnected }) {
            next = "connected"
        } else {
            next = "idle"
        }
        lock.lock()
        phase = next
        lock.unlock()
    }

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        refresh()
    }

    private let sessionKey = "TDSActiveDashboardSession"
    private var retry: DispatchWorkItem?

    func start() {
        guard !running else { return }
        UserDefaults.standard.set(UUID().uuidString, forKey: sessionKey)
        resume()
    }

    func resume() {
        guard let token = UserDefaults.standard.string(forKey: sessionKey) else { return }
        retry?.cancel()
        running = true
        server?.stop()
        server = nil
        addresses = []
        let ips = HTTPServer.shared.getAllIPAddresses().compactMap { entry -> String? in
            guard entry.hasPrefix("en0: ") else { return nil }
            return String(entry.dropFirst(5))
        }
        guard !ips.isEmpty else { retryListening("Waiting for Wi-Fi�"); return }
        let host = HttpServer()
        host["/dashboard"] = { _ in .ok(.html(dashboardHTML)) }
        host["/dashboard/state"] = { [weak self] request in
            guard request.headers["authorization"] == "Bearer " + token, let self = self else {
                return .unauthorized
            }
            self.lock.lock()
            let data = Data(self.phase.utf8)
            self.lock.unlock()
            return .raw(200, "OK", ["Cache-Control":"no-store","Content-Type":"text/plain"]) { try $0.write(data) }
        }
        do {
            try host.start(8081, forceIPv4: true)
            server = host
            let calls = CXCallObserver()
            observer = calls
            calls.setDelegate(self, queue: .main)
            refresh()
            addresses = ips.map { "http://\($0):8081/dashboard#\(token)" }
            running = true
            message = ""
        } catch {
            retryListening(error.localizedDescription)
        }
    }

    private func retryListening(_ reason: String) {
        message = reason
        let task = DispatchWorkItem { [weak self] in self?.resume() }
        retry = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: task)
    }

    func stop() {
        UserDefaults.standard.removeObject(forKey: sessionKey)
        retry?.cancel()
        retry = nil
        message = ""
        server?.stop()
        server = nil
        observer?.setDelegate(nil, queue: nil)
        observer = nil
        addresses = []
        running = false
    }
}

struct DashboardSetup: View {
    @ObservedObject var host = DashboardHost.shared
    var body: some View {
        Form {
            Section {
                Button(host.running ? "Stop dashboard" : "Start dashboard") {
                    if host.running { host.stop() } else { host.start() }
                }
                ForEach(host.addresses, id: \.self) { address in
                    Text(address).font(.footnote).textSelection(.enabled)
                    if let url = URL(string: address) { ShareLink(item: url) }
                }
                if !host.message.isEmpty { Text(host.message) }
            } footer: {
                Text("Open the full link on the same Wi-Fi network. Anyone with the link can see call status until you stop the dashboard.")
            }
        }
        .navigationTitle("Driving dashboard")

    }
}

private let dashboardHTML = #"""
<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>TDS Driving Dashboard</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#101917;color:#f1f6ee;font:1.2rem system-ui}main{max-width:960px;margin:auto;padding:5vw}header,footer{display:flex;justify-content:space-between;gap:1em;flex-wrap:wrap}article{padding:5vh 0}h1{font-size:clamp(2rem,7vw,5rem);margin:.3em 0}strong{font-size:clamp(2rem,6vw,4rem);color:#9ee5b6}aside{background:#d0efd8;color:#142a20;padding:1em;border-radius:.5em;margin:1em 0}small{color:#c4cdc6}
</style><main><header><b>Sample navigation</b><small id="link">Connecting…</small></header>
<aside id="call" role="status" hidden></aside><article><strong>↱ 300 yd</strong><h1>Turn right</h1><p>Station Road</p></article><footer><span>12 min remaining</span><span>4.2 mi</span></footer></main>
<script>
const token=location.hash.slice(1), statusLine=document.querySelector('#link'), banner=document.querySelector('#call');
async function poll(){
  try {
    const r=await fetch('/dashboard/state',{headers:{Authorization:'Bearer '+token},cache:'no-store',signal:AbortSignal.timeout(3500)});
    if(r.status===401){statusLine.textContent='Open the full link from TDS';banner.hidden=true;return}
    if(!r.ok)throw Error();
    const state=await r.text();
    statusLine.textContent='iPhone connected';
    banner.textContent=({incoming:'Incoming call',connected:'Call in progress'})[state]||'';
    banner.hidden=!banner.textContent;
  } catch {statusLine.textContent='iPhone unreachable · reconnecting';banner.hidden=true}
  setTimeout(poll,750);
}poll();
</script></html>
"""#

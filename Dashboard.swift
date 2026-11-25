import CallKit
import SwiftUI
import Swifter

final class DashboardHost: NSObject, ObservableObject, CXCallObserverDelegate {
    static let shared = DashboardHost()
    @Published private(set) var addresses: [String] = []
    @Published private(set) var message = ""
    @Published private(set) var running = false
    @Published private(set) var code = ""
    private var nextAttempt = Date.distantPast
    private var server: HttpServer?
    private var observer: CXCallObserver?
    private let lock = NSLock()
    private var trip = TripDisplay()
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
        guard !ips.isEmpty else { retryListening("Waiting for Wi-Fi..."); return }
        if code.isEmpty { code = String(Int.random(in: 100000...999999)) }
        DrivingTrip.shared.onUpdate = { [weak self] value in
            guard let self = self else { return }
            self.lock.lock(); self.trip = value; self.lock.unlock()
        }
        let pin = code
        let host = HttpServer()
        host["/"] = { _ in .ok(.html(dashboardHTML)) }
        host.POST["/pair"] = { [weak self] req in
            guard let self = self else { return .forbidden }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard Date() >= self.nextAttempt else { return .raw(429, "Too Many Requests", nil, nil) }
            self.nextAttempt = Date().addingTimeInterval(2)
            guard req.headers["x-dashboard-code"] == pin else { return .unauthorized }
            return .raw(204, "No Content", ["Cache-Control":"no-store", "Set-Cookie":"tds=" + token + "; HttpOnly; SameSite=Strict; Path=/dashboard; Max-Age=2592000"], nil)
        }
        host["/dashboard"] = { _ in .ok(.html(dashboardHTML)) }
        host["/dashboard/live"] = { [weak self] request in
            let cookies = (request.headers["cookie"] ?? "").components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cookies.contains("tds=" + token) || request.headers["authorization"] == "Bearer " + token, let self = self else {
                return .unauthorized
            }
            self.lock.lock()
            let snapshot = DashboardPayload(call: self.phase, trip: self.trip)
            self.lock.unlock()
            guard let data = try? JSONEncoder().encode(snapshot) else { return .internalServerError }
            return .raw(200, "OK", ["Cache-Control":"no-store","Content-Type":"application/json"]) { try $0.write(data) }
        }
        do {
            try host.start(8081, forceIPv4: true)
            server = host
            let calls = CXCallObserver()
            observer = calls
            calls.setDelegate(self, queue: .main)
            refresh()
            addresses = ips.map { "http://\($0):8081" }
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
        DrivingTrip.shared.stop()
        server?.stop()
        server = nil
        observer?.setDelegate(nil, queue: nil)
        observer = nil
        addresses = []
        code = ""
        running = false
    }
}

private struct DashboardPayload: Encodable {
    let call: String
    let trip: TripDisplay
}
struct DashboardSetup: View {
    @ObservedObject var trip = DrivingTrip.shared
    @State private var destination = ""

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
                if host.running && !host.addresses.isEmpty { Text("Pairing code: \(host.code)") }
                if !host.message.isEmpty { Text(host.message) }
            } footer: {
                Text("Open the address on the same Wi-Fi and enter the code once per browser. Stop dashboard resets pairing.")
            }
            if host.running {
                Section("Navigation") {
                    TextField("Destination or full address", text: $destination)
                    if trip.active {
                        Text(trip.display.destination)
                        Text(trip.display.title)
                        Button("End trip") { trip.stop() }
                    } else {
                        Button("Start trip") { trip.start(destination) }
                            .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text(trip.display.title)
                    }
                    Text("During a trip TDS uses your location for driving directions, including while locked. End trip stops location updates.").font(.footnote)
                }
            }
        }
        .navigationTitle("Driving dashboard")

    }
}

private let dashboardHTML = #"""
<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>TDS Driving Dashboard</title>
<style>
*{box-sizing:border-box}body{margin:0;color:#f5f8fa;background:#101718;font:clamp(16px,2vw,23px) system-ui}main{min-height:100vh;display:grid;grid-template-columns:5.5rem 1fr;gap:1rem;padding:1rem}header{border-radius:1.3rem;background:#263234;text-align:center;padding:1em .2em}time{font-weight:700}header b{display:block;margin-top:1.2em;color:#8deac1;font-size:.8em}section{position:relative;min-height:80vh;border-radius:1.5rem;overflow:hidden;background:#203b35;padding:1rem;display:flex;flex-direction:column;align-items:flex-start;justify-content:space-between}svg{position:absolute;inset:0;width:100%;height:100%}article,footer,form,aside{position:relative;border-radius:1rem;padding:.8em 1em;background:#102720f5;max-width:95%}article{max-width:min(31rem,90%)}strong{color:#9afbc5}h1{font-size:clamp(1.4rem,3.2vw,3rem);line-height:1.08;margin:.2em 0}footer{margin-top:auto}footer span+span{margin-left:.8em}small{display:block;color:#c9d6cd;margin-top:.35em}aside{background:#d7ffe7;color:#15331e;margin:.5em 0;font-weight:700}form{z-index:1}input,button{font:inherit;border-radius:.5em;padding:.3em}button{cursor:pointer}@media(max-width:550px){main{grid-template-columns:1fr}header{display:flex;align-items:center;justify-content:space-between;padding:.5rem 1rem}header b{margin:0}}
</style><main><header><time></time><b>Drive</b></header><section aria-label="Trip overview">
<svg viewBox="0 0 1000 1000" aria-label="Route outline"><polyline id="line" fill="none" stroke="#68ddff" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/><circle id="dot" r="15" fill="white" stroke="#087aba" stroke-width="7" visibility="hidden"/></svg>
<article><strong id="dist"></strong><h1 id="turn">Choose a destination on iPhone</h1><small id="link">Connecting…</small></article>
<form hidden id="pair"><label>Pairing code <input name="pin" inputmode="numeric" maxlength="6" pattern="[0-9]{6}" required></label> <button>Connect</button><p id="hint"></p></form>
<aside id="call" role="status" hidden></aside><footer><b id="dest">No active trip</b><div><span id="eta"></span><span id="remaining"></span></div></footer></section></main>
<script>
const token=location.hash.slice(1), statusLine=document.querySelector('#link'), banner=document.querySelector('#call');
const form=document.querySelector('#pair'), hint=document.querySelector('#hint');
form.onsubmit=async event=>{
  event.preventDefault();
  try {
    const res=await fetch('/pair',{method:'POST',headers:{'X-Dashboard-Code':form.elements.pin.value},signal:AbortSignal.timeout(3500)});
    if(!res.ok){hint.textContent=res.status===429?'Wait two seconds and retry.':'Check the code on the iPhone.';return}
    form.hidden=true;hint.textContent='';form.reset();poll();
  }catch{hint.textContent='Open TDS and try again.'}
};
function render(t){
  document.querySelector('#turn').textContent=t.title;
  document.querySelector('#dist').textContent=t.detail;
  document.querySelector('#dest').textContent=t.destination||'No active trip';
  document.querySelector('#eta').textContent=t.arrival?'ETA '+t.arrival:'';
  document.querySelector('#remaining').textContent=t.distance;
  document.querySelector('#line').setAttribute('points',t.route.map(p=>p.join(',')).join(' '));
  const dot=document.querySelector('#dot');
  dot.setAttribute('visibility',t.position.length?'visible':'hidden');
  if(t.position.length){dot.setAttribute('cx',t.position[0]);dot.setAttribute('cy',t.position[1])}
}
function clock(){document.querySelector('time').textContent=new Date().toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})}clock();setInterval(clock,15000);
async function poll(){
  try {
    const r=await fetch('/dashboard/live',{headers:{Authorization:'Bearer '+token},cache:'no-store',signal:AbortSignal.timeout(3500)});
    if(r.status===401){form.hidden=false;statusLine.textContent='Pair this browser';banner.hidden=true;return}
    if(!r.ok)throw Error();
    const live=await r.json();render(live.trip);const state=live.call;
    statusLine.textContent='iPhone connected';
    banner.textContent=({incoming:'Incoming call',connected:'Call in progress'})[state]||'';
    banner.hidden=!banner.textContent;
  } catch {statusLine.textContent='iPhone unreachable · reconnecting';banner.hidden=true}
  setTimeout(poll,750);
}poll();
</script></html>
"""#

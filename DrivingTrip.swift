import Foundation
import MapKit

struct TripDisplay: Codable {
    var title = "Choose a destination on iPhone"
    var detail = ""
    var destination = ""
    var distance = ""
    var arrival = ""
    var route: [[Double]] = []
    var position: [Double] = []
}

final class DrivingTrip: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = DrivingTrip()
    @Published private(set) var active = false
    @Published private(set) var display = TripDisplay() {
        didSet { onUpdate?(display) }
    }
    var onUpdate: ((TripDisplay) -> Void)?
    private let gps = CLLocationManager()
    private var target: CLLocationCoordinate2D?
    private var request: MKDirections?
    private var search: MKLocalSearch?
    private var route: MKRoute?
    private var lastRequest = Date.distantPast
    private var generation = UUID()
    private var bounds = MKMapRect.null

    override init() {
        super.init()
        gps.delegate = self
        gps.activityType = .automotiveNavigation
        gps.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        gps.distanceFilter = 8
    }

    func start(_ address: String) {
        stop()
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        active = true
        display.title = "Finding destination"
        display.destination = address
        let id = generation
        let query = MKLocalSearch.Request()
        query.naturalLanguageQuery = address
        if let here = gps.location {
            query.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 50000, longitudinalMeters: 50000)
        }
        let lookup = MKLocalSearch(request: query)
        search = lookup
        lookup.start { [weak self] result, error in
            guard let self = self, self.generation == id else { return }
            guard let item = result?.mapItems.first else {
                self.finish(error?.localizedDescription ?? "Destination not found")
                return
            }
            self.startGuidance(to: item.placemark.coordinate, name: item.name ?? address)
        }
    }

    func startGuidance(to coordinate: CLLocationCoordinate2D, name: String) {
        active = true
        target = coordinate
        display.destination = name
        display.title = "Waiting for location"
        if gps.authorizationStatus == .notDetermined { gps.requestWhenInUseAuthorization() }
        enableLocation()
    }

    private func enableLocation() {
        guard active, target != nil else { return }
        switch gps.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            gps.allowsBackgroundLocationUpdates = true
            gps.showsBackgroundLocationIndicator = true
            gps.startUpdatingLocation()
        case .denied, .restricted: finish("Location access is required for this trip")
        default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { enableLocation() }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied { finish("Location access was denied") }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active, let dest = target, let here = locations.last, here.horizontalAccuracy >= 0,
              here.horizontalAccuracy < 100, abs(here.timestamp.timeIntervalSinceNow) < 30 else { return }
        let goal = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
        if here.distance(from: goal) < 35 { finish("Arrived at " + display.destination); return }
        if let route = route { update(route, here: here) }
        else if request == nil && Date().timeIntervalSince(lastRequest) > 12 { calculate(here, dest) }
    }

    private func calculate(_ here: CLLocation, _ dest: CLLocationCoordinate2D) {
        lastRequest = Date()
        let options = MKDirections.Request()
        options.source = MKMapItem(placemark: MKPlacemark(coordinate: here.coordinate))
        options.destination = MKMapItem(placemark: MKPlacemark(coordinate: dest))
        options.transportType = .automobile
        let directions = MKDirections(request: options)
        request = directions
        if route == nil { display.title = "Calculating route" }
        directions.calculate { [weak self] response, error in
            guard let self = self, self.request === directions else { return }
            self.request = nil
            guard let next = response?.routes.first else {
                self.route = nil
                self.display = TripDisplay(title: "Directions unavailable", detail: error?.localizedDescription ?? "Try again shortly", destination: self.display.destination)
                return
            }
            self.route = next
            let rect = next.polyline.boundingMapRect
            let side = max(rect.width, rect.height, 1) * 1.12
            self.bounds = MKMapRect(x: rect.midX - side/2, y: rect.midY - side/2, width: side, height: side)
            let line = next.polyline
            let strideSize = max(1, line.pointCount / 500)
            var vertices = stride(from: 0, to: line.pointCount, by: strideSize).map { self.xy(line.points()[$0]) }
            if line.pointCount > 0 { vertices.append(self.xy(line.points()[line.pointCount-1])) }
            self.display.route = vertices
            self.update(next, here: self.gps.location ?? here)
        }
    }

    private func xy(_ p: MKMapPoint) -> [Double] {
        [(p.x-bounds.minX)/bounds.width*1000,(p.y-bounds.minY)/bounds.height*1000]
    }

    private func update(_ route: MKRoute, here: CLLocation) {
        let point = MKMapPoint(here.coordinate)
        var closest = Double.infinity, remaining = 0.0, stepRemaining = 0.0, chosen = 0
        var walked = 0.0
        for (idx, step) in route.steps.enumerated() {
            let line = step.polyline
            var within = 0.0
            for i in 1..<max(1,line.pointCount) {
                let a = line.points()[i-1], b = line.points()[i]
                let dx = b.x-a.x, dy = b.y-a.y
                let t = max(0,min(1,((point.x-a.x)*dx+(point.y-a.y)*dy)/max(0.000001,dx*dx+dy*dy)))
                let offset = point.distance(to: MKMapPoint(x:a.x+t*dx,y:a.y+t*dy))
                let length = a.distance(to:b)
                if offset < closest {
                    closest = offset; chosen = idx
                    stepRemaining = max(0,step.distance-within-t*length)
                    remaining = max(0,route.distance-walked-within-t*length)
                }
                within += length
            }
            walked += step.distance
        }
        if closest > 85 {
            display.title = "Off route"
            display.detail = "Recalculating directions"
            display.arrival = ""; display.distance = ""
            if request == nil, Date().timeIntervalSince(lastRequest)>12, let dest = target { calculate(here,dest) }
        } else {
            let next = route.steps.dropFirst(chosen+1).first { !$0.instructions.isEmpty }
            display.title = next?.instructions ?? "Continue to destination"
            display.detail = Self.distance(stepRemaining)
            display.distance = Self.distance(remaining)
            let seconds = route.expectedTravelTime * min(1,remaining/max(1,route.distance))
            display.arrival = DateFormatter.localizedString(from: Date().addingTimeInterval(seconds), dateStyle:.none,timeStyle:.short)
        }
        display.position = xy(point)
    }

    private static func distance(_ m: Double) -> String {
        m < 300 ? String(format:"%.0f yd",m*1.09361) : String(format:"%.1f mi",m/1609.344)
    }
    private func finish(_ text: String) { stop(); display.title = text }
    func stop() {
        generation = UUID()
        search?.cancel(); search = nil
        request?.cancel(); request = nil
        gps.stopUpdatingLocation(); gps.allowsBackgroundLocationUpdates = false
        target = nil; route = nil; active = false; lastRequest = .distantPast
        display = TripDisplay()
    }
}

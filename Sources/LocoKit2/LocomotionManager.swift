//
//  LocomotionManager.swift
//
//
//  Created by Matt Greenfield on 26/2/24.
//

import Foundation
import Observation
import CoreLocation

@Observable
public final class LocomotionManager {

    public static let highlander = LocomotionManager()

    // MARK: - Public
    
    public var sleepCycleDuration: TimeInterval = 20
    public var fallbackUpdateDuration: TimeInterval = 6

    public private(set) var recordingState: RecordingState = .off
    public internal(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    public private(set) var rawLocations: [CLLocation] = []
    public private(set) var filteredLocations: [CLLocation] = [] 

    public private(set) var currentMovingState: MovingStateDetails?
    public private(set) var lastKnownMovingState: MovingStateDetails?
    public private(set) var sleepDetectorState: SleepDetectorState?

    // MARK: -
    
    public func startRecording() {
        DebugLogger.logger.info("LocomotionManager.startRecording()")

        backgroundSession = CLBackgroundActivitySession()

        recordingState = .recording

        locationManager.startUpdatingLocation()
        locationManager.startMonitoringSignificantLocationChanges()
        sleepLocationManager.stopUpdatingLocation()

        restartTheFallbackTimer()

        Task { await stationaryDetector.unfreeze() }
    }

    public func stopRecording() {
        DebugLogger.logger.info("LocomotionManager.stopRecording()")

        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
        sleepLocationManager.stopUpdatingLocation()

        backgroundSession?.invalidate()
        backgroundSession = nil

        stopTheFallbackTimer()
        stopTheWakeupTimer()

        recordingState = .off
    }

    public func requestAuthorization() {
        DebugLogger.logger.info("LocomotionManager.requestAuthorization()")
        locationManager.requestAlwaysAuthorization()
    }

    // MARK: - Private

    private var backgroundSession: CLBackgroundActivitySession?
    private let kalmanFilter = KalmanFilter()
    private let stationaryDetector = StationaryStateDetector()
    private let sleepModeDetector = SleepModeDetector()
    private var fallbackUpdateTimer: Timer?
    private var wakeupTimer: Timer?

    // MARK: -

    private init() {
        _ = locationManager
    }

    // MARK: - State changes

    private func startSleeping() {
        if recordingState != .wakeup {
            DebugLogger.logger.info("LocomotionManager.startSleeping()")
        }

        sleepLocationManager.startUpdatingLocation()
        sleepLocationManager.startMonitoringSignificantLocationChanges()
        locationManager.stopUpdatingLocation()

        recordingState = .sleeping

        restartTheWakeupTimer()

        Task { await stationaryDetector.freeze() }
    }

    private func startWakeup() {
        if recordingState == .wakeup { return }
        if recordingState == .recording { return }

        locationManager.startUpdatingLocation()

        // need to be able to detect nolos
        restartTheFallbackTimer()

        recordingState = .wakeup
    }

    // MARK: - Incoming locations handling

    internal func add(location: CLLocation) async {
        if RecordingState.sleepStates.contains(recordingState) {
            print("Ignoring location during sleep")
            return
        }

        await kalmanFilter.add(location: location)
        let kalmanLocation = await kalmanFilter.currentEstimatedLocation()
        
        await stationaryDetector.add(location: kalmanLocation)
        let currentState = await stationaryDetector.currentState
        let lastKnownState = await stationaryDetector.lastKnownState

        await sleepModeDetector.add(location: kalmanLocation)
        let sleepState = await sleepModeDetector.state

        await MainActor.run {
            rawLocations.append(location)
            filteredLocations.append(kalmanLocation)
            currentMovingState = currentState
            lastKnownMovingState = lastKnownState
            sleepDetectorState = sleepState
        }

        await updateTheRecordingState()
    }

    private func updateTheRecordingState() async {
        let sleepState = await sleepModeDetector.state
        await MainActor.run { sleepDetectorState = sleepState }

        switch recordingState {
        case .recording:
            if sleepState.shouldBeSleeping {
                startSleeping()
            } else {
                restartTheFallbackTimer()
            }   

        case .wakeup:
            if sleepState.shouldBeSleeping {
                startSleeping()
            } else {
                startRecording()
            }

        case .sleeping, .deepSleeping:
            break

        case .standby, .off:
            break
        }
    }

    // MARK: - Timer handling

    private func restartTheFallbackTimer() {
        Task { @MainActor in
            fallbackUpdateTimer?.invalidate()
            fallbackUpdateTimer = Timer.scheduledTimer(withTimeInterval: fallbackUpdateDuration, repeats: false) { [weak self] _ in
                if let self {
                    Task { await self.updateTheRecordingState() }
                }
            }
        }
    }

    private func restartTheWakeupTimer() {
        Task { @MainActor in
            wakeupTimer?.invalidate()
            wakeupTimer = Timer.scheduledTimer(withTimeInterval: sleepCycleDuration, repeats: false) { [weak self] _ in
                self?.startWakeup()
            }
        }
    }

    private func stopTheFallbackTimer() {
        fallbackUpdateTimer?.invalidate()
        fallbackUpdateTimer = nil
    }

    private func stopTheWakeupTimer() {
        wakeupTimer?.invalidate()
        wakeupTimer = nil
    }

    // MARK: - Location Managers

    @ObservationIgnored
    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.distanceFilter = 3
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = false
        manager.allowsBackgroundLocationUpdates = true
        manager.delegate = self.locationDelegate
        return manager
    }()

    @ObservationIgnored
    private lazy var sleepLocationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.distanceFilter = kCLLocationAccuracyThreeKilometers
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        manager.allowsBackgroundLocationUpdates = true
        manager.delegate = self.locationDelegate
        return manager
    }()

    @ObservationIgnored
    private lazy var locationDelegate = {
        return Delegate(parent: self)
    }()

    // MARK: - Debug simulated locations

    func simulated(
        from initialLocation: CLLocation,
        displacementMeters: Double,
        displacementCourse: CLLocationDirection,
        elapsedTime: TimeInterval, // Added parameter for explicit control over time delta
        speed: CLLocationSpeed? = nil, // nil to calculate based on displacement and elapsedTime
        course: CLLocationDirection? = nil, // nil to use displacementCourse
        horizontalAccuracy: CLLocationAccuracy = 10,
        speedAccuracy: CLLocationAccuracy? = nil
    ) -> CLLocation {

        // Calculate the new latitude and longitude based on the displacement and course
        let bearingRadians = displacementCourse * .pi / 180.0
        let distanceRadians = displacementMeters / 6372797.6 // Earth's radius in meters
        let initialLatRadians = initialLocation.coordinate.latitude * .pi / 180.0
        let initialLonRadians = initialLocation.coordinate.longitude * .pi / 180.0

        let newLatRadians = asin(
            sin(initialLatRadians) * cos(distanceRadians) +
            cos(initialLatRadians) * sin(distanceRadians) * cos(bearingRadians)
        )
        let newLonRadians = initialLonRadians + atan2(
            sin(bearingRadians) * sin(distanceRadians) * cos(initialLatRadians),
            cos(distanceRadians) - sin(initialLatRadians) * sin(newLatRadians)
        )

        let newLatitude = newLatRadians * 180.0 / .pi
        let newLongitude = newLonRadians * 180.0 / .pi

        // Calculate speed based on displacement and elapsedTime if not provided
        let calculatedSpeed = speed ?? (displacementMeters / elapsedTime)

        // Set default speed accuracy if not provided
        let finalSpeedAccuracy = speedAccuracy ?? 1.0 // Assuming a default speed accuracy if not specified

        // Create the new CLLocation
        let newLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: newLatitude, longitude: newLongitude),
            altitude: initialLocation.altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: initialLocation.verticalAccuracy,
            course: course ?? displacementCourse,
            courseAccuracy: course != nil ? 0 : 5, // Assuming a default course accuracy
            speed: calculatedSpeed,
            speedAccuracy: finalSpeedAccuracy,
            timestamp: initialLocation.timestamp + elapsedTime
        )

        return newLocation
    }

    // MARK: - CLLocationManagerDelegate

    private class Delegate: NSObject, CLLocationManagerDelegate {
        let parent: LocomotionManager

        init(parent: LocomotionManager) {
            self.parent = parent
            super.init()
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            Task {
                for location in locations {
                    await parent.add(location: location)
                }
            }
        }

        func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
            DebugLogger.logger.info("locationManagerDidPauseLocationUpdates()")
            parent.startSleeping()
        }

        func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
            DebugLogger.logger.info("locationManagerDidResumeLocationUpdates()")
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            parent.authorizationStatus = manager.authorizationStatus
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            DebugLogger.logger.error(error, subsystem: .misc)
        }
    }

}

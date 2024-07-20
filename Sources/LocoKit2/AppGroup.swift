//
//  AppGroup.swift
//
//  Created by Matt Greenfield on 28/5/20.
//

import Foundation
import UIKit

public extension NSNotification.Name {
    static let timelineObjectsExternallyModified = Notification.Name("timelineObjectsExternallyModified")
}

public final class AppGroup: @unchecked Sendable {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Properties

    public let thisApp: AppName
    public let suiteName: String

    public private(set) var apps: [AppName: AppState] = [:]
    public private(set) var applicationState: UIApplication.State = .background
    public private(set) lazy var groupDefaults: UserDefaults? = { UserDefaults(suiteName: suiteName) }()

    public var sortedApps: [AppState] { apps.values.sorted { $0.updated > $1.updated } }
    public var currentRecorder: AppState? { sortedApps.first { $0.isAliveAndRecording } }
    public var haveMultipleRecorders: Bool { apps.values.filter({ $0.isAliveAndRecording }).count > 1 }
    public var haveAppsInStandby: Bool { apps.values.filter({ $0.recordingState == .standby }).count > 0 }

    private lazy var talker: AppGroupTalk = { AppGroupTalk(messagePrefix: suiteName, appName: thisApp) }()

    private let loco = LocomotionManager.highlander
    private let timeline = TimelineRecorder.highlander

    // MARK: - Public methods

    public init(appName: AppName, suiteName: String, readOnly: Bool = false) {
        self.thisApp = appName
        self.suiteName = suiteName

        if readOnly { load(); return }

        save()

        let center = NotificationCenter.default
        center.addObserver(forName: .receivedAppGroupMessage, object: nil, queue: nil) { [weak self] note in
            guard let messageRaw = note.userInfo?["message"] as? String else { return }
            guard let message = AppGroup.Message(rawValue: messageRaw.deletingPrefix(suiteName + ".")) else { return }
            self?.received(message)
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] note in
            self?.applicationState = .active
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] note in
            self?.applicationState = .background
        }
    }

    public var shouldBeTheRecorder: Bool {
        // should always be current recorder in foreground
        if applicationState == .active { return true }

        // there's no current recorder? then we should take on the job
        guard let currentRecorder = currentRecorder else { return true }

        // TODO: Arc Recorder shouldn't concede to others
        
        // there's multiple recorders, and we're not in foreground? it's time to concede
        if haveMultipleRecorders { return false }

        // if this app is the current recorder, it should continue to be so
        return currentRecorder.appName == thisApp
    }

    public var isAnActiveRecorder: Bool {
        return currentAppState.recordingState.isCurrentRecorder
    }

    public func becameCurrentRecorder() {
        save()
        send(message: .tookOverRecording)
    }

    // MARK: - 

    public func load() {
        let fileManager = FileManager.default
        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: suiteName) else {
            return
        }

        let fileURLs = try? fileManager.contentsOfDirectory(at: containerURL, includingPropertiesForKeys: nil)
        let stateFileURLs = fileURLs?.filter { $0.pathExtension == "json" }

        var states: [AppName: AppState] = [:]
        for fileURL in stateFileURLs ?? [] {
            if let state = try? AppState.loadFromFile(url: fileURL) {
                states[state.appName] = state
            }
        }

        apps = states
    }

    public func save() {
        let fileManager = FileManager.default
        guard let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: suiteName) else {
            return
        }

        let fileURL = containerURL.appendingPathComponent("AppState_\(thisApp.rawValue).json")
        try? currentAppState.saveToFile(url: fileURL)

        send(message: .updatedState)
    }

    var currentAppState: AppState {
        return AppState(
            appName: thisApp,
            recordingState: loco.recordingState,
            currentItemId: timeline.currentItemId
        )
    }

    public func notifyObjectChanges(objectIds: Set<UUID>) {
        let messageInfo = MessageInfo(date: .now, message: .modifiedObjects, appName: thisApp, modifiedObjectIds: objectIds)
        send(message: .modifiedObjects, messageInfo: messageInfo)
    }
    
    // MARK: - Shared settings
    
    public func get(setting key: String) -> Any? {
        return groupDefaults?.value(forKey: "sharedSetting." + key) as Any?
    }
    
    public func set(setting key: String, value: Any?) {
        groupDefaults?.set(value, forKey: "sharedSetting." + key)
    }

    // MARK: - Private

    private func send(message: Message, messageInfo: MessageInfo? = nil) {
        let lastMessage = messageInfo ?? MessageInfo(date: .now, message: message, appName: thisApp, modifiedObjectIds: nil)
        if let data = try? encoder.encode(lastMessage) {
            groupDefaults?.set(data, forKey: "lastMessage")
        }
        talker.send(message)
    }

    private func received(_ message: AppGroup.Message) {
        guard let data = groupDefaults?.value(forKey: "lastMessage") as? Data else { return }
        guard let messageInfo = try? decoder.decode(MessageInfo.self, from: data) else { return }
        guard messageInfo.appName != thisApp else { return }
        guard messageInfo.message == message else {
            logger.debug("LASTMESSAGE MISMATCH (expected: \(message.rawValue), got: \(messageInfo.message.rawValue))")
            return
        }

        load()

        switch message {
        case .updatedState:
            appStateUpdated(by: messageInfo.appName)
        case .modifiedObjects:
            objectsWereModified(by: messageInfo.appName, messageInfo: messageInfo)
        case .tookOverRecording:
            recordingWasTakenOver(by: messageInfo.appName, messageInfo: messageInfo)
        }
    }
    
    private func appStateUpdated(by: AppName) {
        logger.debug("RECEIVED: .updatedState, from: \(by.rawValue)")

        guard let currentRecorder else {
            logger.error("No AppGroup.currentRecorder", subsystem: .appgroup)
            return
        }
        guard let currentItemId = currentRecorder.currentItemId else {
            logger.error("No AppGroup.currentItemId", subsystem: .appgroup)
            return
        }

        if !isAnActiveRecorder, currentAppState.currentItemId != currentItemId {
            logger.debug("Local currentItemId is stale (mine: \(self.currentAppState.currentItemId ?? "nil"), theirs: \(currentItemId))")
            timeline.updateCurrentItemId()
        }
    }

    private func recordingWasTakenOver(by: AppName, messageInfo: MessageInfo) {
        if LocomotionManager.highlander.recordingState.isCurrentRecorder {
            LocomotionManager.highlander.startStandby()
            
            let appName = LocomotionManager.highlander.appGroup?.currentRecorder?.appName.rawValue ?? "UNKNOWN"
            logger.info("concededRecording to \(appName)", subsystem: .misc)
        }
    }

    private func objectsWereModified(by: AppName, messageInfo: MessageInfo) {
        logger.debug("AppGroup received modifiedObjectIds: \(messageInfo.modifiedObjectIds?.count ?? 0) by: \(by.rawValue)")
        if let objectIds = messageInfo.modifiedObjectIds, !objectIds.isEmpty {
            let note = Notification(name: .timelineObjectsExternallyModified, object: self, userInfo: ["modifiedObjectIds": objectIds])
            NotificationCenter.default.post(note)
        }
    }

    // MARK: - Interfaces

    public enum AppName: String, CaseIterable, Codable, Sendable {
        case arcV3, arcMini, arcRecorder, arcEditor
        public var sortIndex: Int {
            switch self {
            case .arcV3: return 0
            case .arcMini: return 1
            case .arcRecorder: return 2
            case .arcEditor: return 3
            }
        }
    }

    public struct AppState: Codable, Sendable {
        public let appName: AppName
        public let recordingState: RecordingState
        public var currentItemId: String?
        public var updated = Date()

        public var isAlive: Bool {
            return updated.age < LocomotionManager.highlander.standbyCycleDuration + 3
        }

        public var isAliveAndRecording: Bool {
            return isAlive && recordingState != .off && recordingState != .standby
        }

        public func saveToFile(url: URL) throws {
            let data = try JSONEncoder().encode(self)
            try data.write(to: url)
        }

        public static func loadFromFile(url: URL) throws -> AppState {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppState.self, from: data)
        }
    }

    public enum Message: String, CaseIterable, Codable, Sendable {
        case updatedState
        case modifiedObjects
        case tookOverRecording
        func withPrefix(_ prefix: String) -> String { return "\(prefix).\(rawValue)" }
    }

    public struct MessageInfo: Codable, Sendable {
        public var date: Date
        public var message: Message
        public var appName: AppName
        public var modifiedObjectIds: Set<UUID>? = nil
    }

}

// MARK: -

extension NSNotification.Name {
    static let receivedAppGroupMessage = Notification.Name("receivedAppGroupMessage")
}

// MARK: -

// https://stackoverflow.com/a/58188965/790036
final public class AppGroupTalk: NSObject {

    private let center = CFNotificationCenterGetDarwinNotifyCenter()
    private let messagePrefix: String
    private let appName: AppGroup.AppName

    public init(messagePrefix: String, appName: AppGroup.AppName) {
        self.messagePrefix = messagePrefix
        self.appName = appName
        super.init()
        startListeners()
    }

    deinit {
        stopListeners()
    }

    // MARK: -

    public func send(_ message: AppGroup.Message) {
        let noteName = CFNotificationName(rawValue: message.withPrefix(messagePrefix) as CFString)
        CFNotificationCenterPostNotification(center, noteName, nil, nil, true)
    }

    // MARK: - Private

    private func startListeners() {
        for message in AppGroup.Message.allCases {
            CFNotificationCenterAddObserver(center, Unmanaged.passRetained(self).toOpaque(), { center, observer, name, object, userInfo in
                NotificationCenter.default.post(name: .receivedAppGroupMessage, object: nil, userInfo: ["message": name?.rawValue as Any])
            }, "\(messagePrefix).\(message.rawValue)" as CFString, nil, .deliverImmediately)
        }
    }

    private func stopListeners() {
        CFNotificationCenterRemoveEveryObserver(center, Unmanaged.passRetained(self).toOpaque())
    }

}

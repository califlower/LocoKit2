//
//  RecordingState.swift
//
//
//  Created by Matt Greenfield on 26/2/24.
//

import Foundation

public enum RecordingState: Int, Codable {
    case off = 0
    case recording = 1
    case sleeping = 2
    case deepSleeping = 3
    case wakeup = 4
    case standby = 5

    public static let sleepStates = [sleeping, deepSleeping]

    public var stringValue: String {
        switch self {
        case .off:          return "off"
        case .recording:    return "recording"
        case .sleeping:     return "sleeping"
        case .deepSleeping: return "deepSleeping"
        case .wakeup:       return "wakeup"
        case .standby:      return "standby"
        }
    }
}

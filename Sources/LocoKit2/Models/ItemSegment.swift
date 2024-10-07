//
//  ItemSegment.swift
//  LocoKit2
//
//  Created by Matt Greenfield on 2024-09-25.
//

import Foundation
import GRDB

public struct ItemSegment: Hashable, Sendable {
    public let samples: [LocomotionSample]
    public let dateRange: DateInterval

    init?(samples: [LocomotionSample]) {
        if samples.isEmpty {
            return nil
        }

        let dates = samples.map { $0.date }
        guard let startDate = dates.min(), let endDate = dates.max() else {
            return nil
        }

        self.samples = samples.sorted { $0.date < $1.date }
        self.dateRange = DateInterval(start: startDate, end: endDate)
    }

    // MARK: - Validity

    // there's no extra samples either in segment or db for the segment's dateRange
    public func validateIsContiguous() async throws -> Bool {
        let dbSampleIds = try await Database.pool.read { db in
            let request = LocomotionSample
                .select(Column("id"))
                .filter(dateRange.range.contains(Column("date")))
            return try String.fetchSet(db, request)
        }

        return dbSampleIds == Set(samples.map { $0.id })
    }

    // MARK: - ActivityTypes

    public var activityType: ActivityType? {
        return samples.first?.activityType
    }

    public func confirmActivityType(_ confirmedType: ActivityType) async {
        do {
            try await Database.pool.write { db in
                for var sample in samples where sample.confirmedActivityType != confirmedType {
                    try sample.updateChanges(db) {
                        $0.confirmedActivityType = confirmedType
                    }
                }
            }

            await CoreMLModelUpdater.highlander.queueUpdatesForModelsContaining(samples)

        } catch {
            logger.error(error, subsystem: .database)
        }
    }
}

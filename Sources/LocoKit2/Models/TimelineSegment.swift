//
//  TimelineSegment.swift
//
//
//  Created by Matt Greenfield on 23/5/24.
//

import Foundation
import Combine
import UIKit
import GRDB

@Observable
public final class TimelineSegment: Sendable {

    public let dateRange: DateInterval
    public let shouldReprocessOnUpdate: Bool

    @MainActor
    public private(set) var timelineItems: [TimelineItem] = []

    @ObservationIgnored
    nonisolated(unsafe)
    private var changesTask: Task<Void, Never>?

    @ObservationIgnored
    nonisolated(unsafe)
    private let updateDebouncer = Debouncer()

    public init(dateRange: DateInterval, shouldReprocessOnUpdate: Bool = false) {
        self.shouldReprocessOnUpdate = shouldReprocessOnUpdate
        self.dateRange = dateRange
        setupObserver()
        Task { await fetchItems() }
    }

    deinit {
        changesTask?.cancel()
    }

    // MARK: -

    private func setupObserver() {
        changesTask = Task { [weak self] in
            for await changedRange in TimelineObserver.highlander.changesStream() {
                guard let self else { return }
                if self.dateRange.intersects(changedRange) {
                    self.updateDebouncer.debounce(duration: 1) { [weak self] in
                        await self?.fetchItems()
                    }
                }
            }
        }
    }

    private func fetchItems() async {
        do {
            let items = try await Database.pool.read { [dateRange] in
                let request = TimelineItemBase
                    .including(optional: TimelineItemBase.visit)
                    .including(optional: TimelineItemBase.trip)
                    .filter(Column("endDate") > dateRange.start && Column("startDate") < dateRange.end)
                    .order(Column("endDate").desc)
                return try TimelineItem.fetchAll($0, request)
            }
            await update(from: items)

        } catch {
            logger.error(error, subsystem: .database)
        }
    }

    private func update(from updatedItems: [TimelineItem]) async {
        var mutableItems = updatedItems

        // no reprocessing in the background
        let doProcessing: Bool
        if shouldReprocessOnUpdate {
            doProcessing = await UIApplication.shared.applicationState == .active
        } else {
            doProcessing = false
        }
        
        for index in mutableItems.indices {
            let itemCopy = mutableItems[index]
            if itemCopy.samplesChanged {
                await mutableItems[index].fetchSamples()

            } else {
                // copy over existing samples if available
                let localItem = await timelineItems.first { $0.id == itemCopy.id }
                if let localItem, let samples = localItem.samples {
                    mutableItems[index].samples = samples

                } else { // need to fetch samples
                    await mutableItems[index].fetchSamples()
                }
            }
        }

        await MainActor.run {
            self.timelineItems = mutableItems
        }

        if doProcessing {
            do {
                try await reprocess()
            } catch {
                logger.error(error, subsystem: .timeline)
            }
        }
    }

    private func reprocess() async throws {
        let workingItems = await timelineItems
        let currentItemId = TimelineRecorder.highlander.currentItemId
        let currentItem = await timelineItems.first { $0.id == currentItemId }

        // shouldn't do processing if currentItem is in the segment and isn't a keeper
        // (TimelineRecorder should be the sole authority on processing those cases)
        if let currentItem, try !currentItem.isWorthKeeping {
            return
        }

        await TimelineProcessor.highlander.process(workingItems)
    }

}

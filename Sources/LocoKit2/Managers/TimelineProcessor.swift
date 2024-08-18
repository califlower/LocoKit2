//
//  TimelineProcessor.swift
//
//
//  Created by Matt Greenfield on 6/6/24.
//

import Foundation
import CoreLocation
import GRDB

@TimelineActor
public final class TimelineProcessor {

    public static let highlander = TimelineProcessor()

    public static let debugLogging = true
    
    public static let maximumModeShiftSpeed = CLLocationSpeed(kmh: 2)

    private let maxProcessingListSize = 21
    private let maximumPotentialMergesInProcessingLoop = 10

    public func processFrom(itemId: String) async {
        do {
            guard let list = try await processingList(fromItemId: itemId) else { return }

            if let results = await process(list) {
                await processFrom(itemId: results.kept.id)
            }
            
        } catch {
            logger.error(error, subsystem: .timeline)
        }
    }

    public func process(_ list: TimelineLinkedList) async -> MergeResult? {
        do {
            try await sanitiseEdges(for: list)

            let merges = try await collectPotentialMerges(for: list)
                .sorted { $0.score.rawValue > $1.score.rawValue }

            // find the highest scoring valid merge
            guard let winningMerge = merges.first, winningMerge.score != .impossible else {
                return nil
            }

            return await winningMerge.doIt()

        } catch {
            logger.error(error, subsystem: .timeline)
            return nil
        }
    }

    // MARK: - Private

    private init() {}

    private func processingList(fromItemId: String) async throws -> TimelineLinkedList? {
        guard let list = await TimelineLinkedList(fromItemId: fromItemId) else { return nil }

        // collect items before seedItem, up to two keepers
        var previousKeepers = 0
        var workingItem = list.seedItem
        while previousKeepers < 2, list.timelineItems.count < maxProcessingListSize, let previous = await workingItem.previousItem(in: list) {
            if try previous.isWorthKeeping { previousKeepers += 1 }
            workingItem = previous
        }

        // collect items after seedItem, up to two keepers
        var nextKeepers = 0
        workingItem = list.seedItem
        while nextKeepers < 2, list.timelineItems.count < maxProcessingListSize, let next = await workingItem.nextItem(in: list) {
            if try next.isWorthKeeping { nextKeepers += 1 }
            workingItem = next
        }

        return list
    }

    // MARK: - Merge collating

    private func collectPotentialMerges(for list: TimelineLinkedList) async throws -> [Merge] {
        var merges: Set<Merge> = []

        for workingItem in list.timelineItems.values {
            if shouldStopCollecting(merges) {
                break
            }

            await collectAdjacentMerges(for: workingItem, in: list, into: &merges)
            try await collectBetweenerMerges(for: workingItem, in: list, into: &merges)
            try await collectBridgeMerges(for: workingItem, in: list, into: &merges)
        }

        return Array(merges)
    }

    private func shouldStopCollecting(_ merges: Set<Merge>) -> Bool {
        merges.count >= maximumPotentialMergesInProcessingLoop && merges.first(where: { $0.score != .impossible }) != nil
    }

    private func collectAdjacentMerges(for item: TimelineItem, in list: TimelineLinkedList, into merges: inout Set<Merge>) async {
        if let next = await item.nextItem(in: list) {
            merges.insert(await Merge(keeper: item, deadman: next, in: list))
            merges.insert(await Merge(keeper: next, deadman: item, in: list))
        }

        if let previous = await item.previousItem(in: list) {
            merges.insert(await Merge(keeper: item, deadman: previous, in: list))
            merges.insert(await Merge(keeper: previous, deadman: item, in: list))
        }
    }

    private func collectBetweenerMerges(for item: TimelineItem, in list: TimelineLinkedList, into merges: inout Set<Merge>) async throws {
        if let next = await item.nextItem(in: list), try !item.isDataGap, try next.keepnessScore < item.keepnessScore {
            if let nextNext = await next.nextItem(in: list), try !nextNext.isDataGap, try nextNext.keepnessScore > next.keepnessScore {
                merges.insert(await Merge(keeper: item, betweener: next, deadman: nextNext, in: list))
                merges.insert(await Merge(keeper: nextNext, betweener: next, deadman: item, in: list))
            }
        }

        if let previous = await item.previousItem(in: list), try !item.isDataGap, try previous.keepnessScore < item.keepnessScore {
            if let prevPrev = await previous.previousItem(in: list), try !prevPrev.isDataGap, try prevPrev.keepnessScore > previous.keepnessScore {
                merges.insert(await Merge(keeper: item, betweener: previous, deadman: prevPrev, in: list))
                merges.insert(await Merge(keeper: prevPrev, betweener: previous, deadman: item, in: list))
            }
        }
    }

    private func collectBridgeMerges(for item: TimelineItem, in list: TimelineLinkedList, into merges: inout Set<Merge>) async throws {
        guard let previous = await item.previousItem(in: list),
              let next = await item.nextItem(in: list),
              previous.source == item.source,
              next.source == item.source,
              try previous.keepnessScore > item.keepnessScore,
              try next.keepnessScore > item.keepnessScore,
              try !previous.isDataGap,
              try !next.isDataGap
        else {
            return
        }

        merges.insert(await Merge(keeper: previous, betweener: item, deadman: next, in: list))
        merges.insert(await Merge(keeper: next, betweener: item, deadman: previous, in: list))
    }

    // MARK: - Edge cleansing

    private var alreadyMovedSamples: Set<LocomotionSample> = []

    private func sanitiseEdges(for list: TimelineLinkedList) async throws {
        var allMoved: Set<LocomotionSample> = []

        for item in list.timelineItems.values {
            let moved = try await item.sanitiseEdges(in: list, excluding: alreadyMovedSamples)
            allMoved.formUnion(moved)
        }

        if TimelineProcessor.debugLogging, !allMoved.isEmpty {
            logger.debug("sanitiseEdges() moved \(allMoved.count) samples")
        }

        alreadyMovedSamples = allMoved
    }

}

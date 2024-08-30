//
//  MergeScores.swift
//  LearnerCoacher
//
//  Created by Matt Greenfield on 15/12/16.
//  Copyright © 2016 Big Paua. All rights reserved.
//

import Foundation

public enum ConsumptionScore: Int {
    case perfect = 5
    case high = 4
    case medium = 3
    case low = 2
    case veryLow = 1
    case impossible = 0
}

@TimelineActor
public final class MergeScores {

    // MARK: - SOMETHING <- SOMETHING
    static func consumptionScoreFor(_ consumer: TimelineItem, toConsume consumee: TimelineItem) -> ConsumptionScore {
        guard let consumerSamples = consumer.samples else { return .impossible }
        guard let consumeeSamples = consumee.samples else { return .impossible }

        // deadmen can't consume anyone
        if consumer.deleted { return .impossible }

        // disabled can't consume or be consumed
        if consumer.disabled || consumee.disabled { return .impossible }

        // can't consume a different source
        if consumer.source != consumee.source { return .impossible }

        // if consumee has zero samples, call it a perfect merge
        if consumeeSamples.isEmpty { return .perfect }

        // if consumer has zero samples, call it impossible
        if consumerSamples.isEmpty { return .impossible }

        do {
            // data gaps can only consume data gaps
            if try consumer.isDataGap { return (try consumee.isDataGap) ? .perfect : .impossible }

            // anyone can consume an invalid data gap, but no one can consume a valid data gap
            if try consumee.isDataGap { return (try consumee.isInvalid) ? .medium : .impossible }

            // nolos can only consume nolos
            if try consumer.isNolo { return (try consumee.isNolo) ? .perfect : .impossible }

            // anyone can consume an invalid nolo
            if try consumee.isNolo && consumee.isInvalid { return .medium }

            // test for impossible separation distance
            guard try consumer.isWithinMergeableDistance(of: consumee) else { return .impossible }

            // visit <- something
            if consumer.isVisit {
                return consumptionScoreFor(visit: consumer, toConsume: consumee)
            } else { // trip <- something
                return try consumptionScoreFor(trip: consumer, toConsume: consumee)
            }

        } catch {
            logger.error("MergeScores.consumptionScoreFor() \(error)", subsystem: .timeline)
            return .impossible
        }
    }

    // MARK: - TRIP <- SOMETHING
    private static func consumptionScoreFor(trip consumer: TimelineItem, toConsume consumee: TimelineItem) throws -> ConsumptionScore {
        guard consumer.isTrip else { fatalError() }

        // consumer is invalid
        if try consumer.isInvalid {

            // invalid <- invalid
            if try consumee.isInvalid { return .veryLow }

            // invalid <- valid
            return .impossible
        }

        // trip <- visit
        if consumee.isVisit { return try consumptionScoreFor(trip: consumer, toConsumeVisit: consumee) }

        // trip <- trip
        if consumee.isTrip { return try consumptionScoreFor(trip: consumer, toConsumeTrip: consumee) }

        return .impossible
    }
    
    // MARK: - TRIP <- VISIT
    private static func consumptionScoreFor(trip consumer: TimelineItem, toConsumeVisit consumee: TimelineItem) throws -> ConsumptionScore {
        guard consumer.isTrip, consumee.isVisit else { fatalError() }

        // can't consume a keeper visit
        if try consumee.isWorthKeeping { return .impossible }

        // consumer is keeper
        if try consumer.isWorthKeeping {

            // keeper <- invalid
            if try consumee.isInvalid { return .medium }

            // keeper  <- valid
            return .low
        }
        
        // consumer is valid
        if try consumer.isValid {

            // valid <- invalid
            if try consumee.isInvalid { return .low }

            // valid <- valid
            return .veryLow
        }
        
        // consumer is invalid (actually already dealt with in previous method)
        return .impossible
    }

    // MARK: - TRIP <- TRIP
    private static func consumptionScoreFor(trip consumer: TimelineItem, toConsumeTrip consumee: TimelineItem) throws -> ConsumptionScore {
        guard consumer.isTrip, consumee.isTrip else { fatalError() }
        guard let consumerTrip = consumer.trip, let consumeeTrip = consumee.trip else { fatalError() }

//        let consumerType = consumer.modeMovingActivityType ?? consumer.modeActivityType
//        let consumeeType = consumee.modeMovingActivityType ?? consumee.modeActivityType

        let consumerType = consumerTrip.activityType
        let consumeeType = consumeeTrip.activityType

        // no types means it's a random guess
        if consumerType == nil && consumeeType == nil { return .medium }

        // perfect type match
        if consumeeType == consumerType { return .perfect }

        // can't consume a keeper path
        if try consumee.isWorthKeeping { return .impossible }

        // a path with nil type can't consume anyone
        guard let scoringType = consumerType else { return .impossible }

//        guard let typeResult = consumee.classifierResults?.first(where: { $0.name == scoringType }) else {
//            return .impossible
//        }

        // consumee's type score for consumer's type, as a usable Int
//        let typeScore = Int(floor(typeResult.score * 1000))
//
//        switch typeScore {
//        case 75...Int.max:
//            return .perfect
//        case 50...75:
//            return .high
//        case 25...50:
//            return .medium
//        case 10...25:
//            return .low
//        default:
//            return .veryLow
//        }

        // TODO: remove this once above actually works
        return .impossible
    }

    // MARK: - VISIT <- SOMETHING
    private static func consumptionScoreFor(visit consumer: TimelineItem, toConsume consumee: TimelineItem) -> ConsumptionScore {
        guard consumer.isVisit else { fatalError() }

        // visit <- visit
        if consumee.isVisit { return consumptionScoreFor(visit: consumer, toConsumeVisit: consumee) }

        // visit <- trip
        if consumee.isTrip { return consumptionScoreFor(visit: consumer, toConsumeTrip: consumee) }

        return .impossible
    }
    
    // MARK: - VISIT <- VISIT
    private static func consumptionScoreFor(visit consumer: TimelineItem, toConsumeVisit consumee: TimelineItem) -> ConsumptionScore {
        guard consumer.isVisit, consumee.isVisit else { fatalError() }
        guard let consumerVisit = consumer.visit, let consumeeVisit = consumee.visit else { fatalError() }

        // overlapping visits
        if consumerVisit.overlaps(consumeeVisit) {
            return consumer.dateRange.duration > consumee.dateRange.duration ? .perfect : .high
        }
        
        return .impossible
    }
    
    // MARK: - VISIT <- TRIP
    private static func consumptionScoreFor(visit consumer: TimelineItem, toConsumeTrip consumee: TimelineItem) -> ConsumptionScore {
        guard consumer.isVisit, consumee.isTrip else { fatalError() }
        guard let consumerVisit = consumer.visit else { return .impossible }

        do {
            let pctInside = try consumee.percentInside(consumerVisit)
            let pctInsideScore = Int(floor(pctInside * 10))

            // valid / keeper visit <- invalid trip
            if try consumer.isValid && consumee.isInvalid {
                switch pctInsideScore {
                case 10: // 100%
                    return .low
                default:
                    return .veryLow
                }
            }

            return .impossible

        } catch {
            logger.error(error, subsystem: .timeline)
            return .impossible
        }
    }

}

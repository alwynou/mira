import Foundation
import Testing
@testable import MiraCore

@Suite("Model stream channel", .timeLimit(.minutes(1)))
struct AgentModelStreamChannelTests {
    @Test func eventsAreBackpressuredAndRemainInOrder() async throws {
        let channel = AgentModelStreamChannel()
        let first = AgentModelStreamEvent.blockStarted(.init(id: "text", content: .text("first")))
        let second = AgentModelStreamEvent.blockStarted(.init(id: "text", content: .text("second")))
        let firstCompletion = TaskCompletionMarker()

        let firstProducer = Task {
            do { try await channel.send(first) }
            catch { await firstCompletion.mark(); throw error }
            await firstCompletion.mark()
        }
        do {
            try await waitUntilBuffered(channel)
            #expect(await firstCompletion.completed == false)
            switch try await channel.next() {
            case .event(let received): #expect(received == first)
            default: Issue.record("first event was not delivered in order")
            }
            try await firstProducer.value

            let secondCompletion = TaskCompletionMarker()
            let secondProducer = Task {
                do { try await channel.send(second) }
                catch { await secondCompletion.mark(); throw error }
                await secondCompletion.mark()
            }
            do {
                try await waitUntilBuffered(channel)
                #expect(await secondCompletion.completed == false)
                switch try await channel.next() {
                case .event(let received): #expect(received == second)
                default: Issue.record("second event was not delivered in order")
                }
                try await secondProducer.value
            } catch {
                secondProducer.cancel()
                await channel.close()
                _ = try? await secondProducer.value
                throw error
            }
        } catch {
            firstProducer.cancel()
            await channel.close()
            _ = try? await firstProducer.value
            throw error
        }
        await channel.close()
    }

    @Test func finishPreservesBufferedEventThenReturnsExactTerminalOutcome() async throws {
        let completed = AgentModelStreamChannel()
        let producer = Task { try await completed.send(.blockStarted(.init(id: "text", content: .text("buffered")))) }
        do {
            try await waitUntilBuffered(completed)
            await completed.finish()
            switch try await completed.next() {
            case .event(.blockStarted(.init(id: "text", content: .text("buffered")))): break
            default: Issue.record("finish discarded the buffered event")
            }
            try await producer.value
            let completedEnd = try await completed.next()
            if case .some = completedEnd { Issue.record("completed channel did not return EOF") }
        } catch {
            producer.cancel()
            await completed.close()
            _ = try? await producer.value
            throw error
        }
        await completed.close()

        let failed = AgentModelStreamChannel()
        let expected = MiraError(.network, "synthetic terminal failure")
        let failedProducer = Task { try await failed.send(.blockStarted(.init(id: "text", content: .text("before failure")))) }
        do {
            try await waitUntilBuffered(failed)
            await failed.finish(error: expected)
            switch try await failed.next() {
            case .event(.blockStarted(.init(id: "text", content: .text("before failure")))): break
            default: Issue.record("failure discarded the buffered event")
            }
            try await failedProducer.value
            do {
                _ = try await failed.next()
                Issue.record("failed channel returned EOF instead of its terminal error")
            } catch let error as MiraError {
                #expect(error == expected)
            }
        } catch {
            failedProducer.cancel()
            await failed.close()
            _ = try? await failedProducer.value
            throw error
        }
        await failed.close()
    }

    @Test func liveOutputTicksCoalesceWithoutDurableSignals() async throws {
        let channel = AgentModelStreamChannel()
        for _ in 0..<32 { #expect(await channel.output()) }
        let producer = Task { try await channel.send(.blockStarted(.init(id: "text", content: .text("pending")))) }
        do {
            try await waitUntilBuffered(channel)
            guard case .output = try await channel.next() else {
                throw MiraError(.conflict, "The live output signal was lost.")
            }
            guard case .event(.blockStarted(.init(id: "text", content: .text("pending")))) = try await channel.next() else {
                throw MiraError(.conflict, "Coalesced live-output signals displaced the model event.")
            }
            try await producer.value
            await channel.finish()
            #expect(await !channel.output())
            if case .some = try await channel.next() { Issue.record("Unexpected signal after EOF") }
        } catch {
            producer.cancel(); await channel.close(); _ = await producer.result; throw error
        }
        await channel.close()
    }

    @Test func closeReleasesPendingProducerAndConsumer() async throws {
        let producerChannel = AgentModelStreamChannel()
        let producer = Task { try await producerChannel.send(.blockStarted(.init(id: "text", content: .text("pending")))) }
        do {
            try await waitUntilBuffered(producerChannel)
            await producerChannel.close()
            do {
                try await producer.value
                Issue.record("closing a channel allowed a pending producer to finish")
            } catch is CancellationError { }
            catch { Issue.record("pending producer failed with an unexpected error: \(error)") }
        } catch {
            producer.cancel()
            await producerChannel.close()
            _ = try? await producer.value
            throw error
        }

        let consumerChannel = AgentModelStreamChannel()
        let consumer = Task { try await consumerChannel.next() }
        do {
            try await waitUntilWaiting(consumerChannel)
            await consumerChannel.close()
            do {
                _ = try await consumer.value
                Issue.record("closing a channel allowed a pending consumer to finish")
            } catch is CancellationError { }
            catch { Issue.record("pending consumer failed with an unexpected error: \(error)") }
        } catch {
            consumer.cancel()
            await consumerChannel.close()
            _ = try? await consumer.value
            throw error
        }

        let cancelledProducerChannel = AgentModelStreamChannel()
        let cancelledProducer = Task { try await cancelledProducerChannel.send(.blockStarted(.init(id: "text", content: .text("cancelled")))) }
        do {
            try await waitUntilBuffered(cancelledProducerChannel)
            cancelledProducer.cancel()
            do {
                try await cancelledProducer.value
                Issue.record("cancelling a pending producer did not fail it")
            } catch is CancellationError { }
            catch { Issue.record("cancelled producer failed with an unexpected error: \(error)") }
        } catch {
            cancelledProducer.cancel()
            await cancelledProducerChannel.close()
            _ = try? await cancelledProducer.value
            throw error
        }

        let cancelledConsumerChannel = AgentModelStreamChannel()
        let cancelledConsumer = Task { try await cancelledConsumerChannel.next() }
        do {
            try await waitUntilWaiting(cancelledConsumerChannel)
            cancelledConsumer.cancel()
            do {
                _ = try await cancelledConsumer.value
                Issue.record("cancelling a pending consumer did not fail it")
            } catch is CancellationError { }
            catch { Issue.record("cancelled consumer failed with an unexpected error: \(error)") }
        } catch {
            cancelledConsumer.cancel()
            await cancelledConsumerChannel.close()
            _ = try? await cancelledConsumer.value
            throw error
        }
        await cancelledProducerChannel.close()
        await cancelledConsumerChannel.close()
    }

    private func waitUntilBuffered(_ channel: AgentModelStreamChannel) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(5)
        while clock.now < deadline {
            if await channel.bufferedEventCount == 1 { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw MiraError(.timeout, "The test producer did not reach the channel buffer.")
    }

    private func waitUntilWaiting(_ channel: AgentModelStreamChannel) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now + .seconds(5)
        while clock.now < deadline {
            if await channel.isWaitingForInput { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw MiraError(.timeout, "The test consumer did not wait on the channel.")
    }
}

private actor TaskCompletionMarker {
    private(set) var completed = false
    func mark() { completed = true }
}

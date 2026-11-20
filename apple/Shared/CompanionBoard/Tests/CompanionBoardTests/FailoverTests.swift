import XCTest
@testable import CompanionBoard

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func profile(_ id: String, _ place: ModelProfile.Place, _ tier: ModelProfile.Tier) -> ModelProfile {
    ModelProfile(id: id, choice: ModelChoice(engine: place.rawValue, model: id), name: id, place: place,
                 window: 200_000, tier: tier, tools: true)
}

final class FailoverTests: XCTestCase {
    private func trouble(_ status: Int?, _ message: String) -> Failover.Trouble? {
        Failover.trouble(status: status, message: message, now: now)?.trouble
    }

    func testAModelOutOfItsLimitIsToldFromWhatItAnswered() {
        // Subscription tools, in their own words.
        XCTAssertEqual(trouble(nil, "Claude Code: You've hit your limit · resets 3pm"), .limit)
        XCTAssertEqual(trouble(nil, "Claude Code: You've reached your Fable limit"), .limit)
        XCTAssertEqual(trouble(nil, "Claude Code: You've hit your Opus limit · resets 3pm"), .limit)
        XCTAssertEqual(trouble(nil, "Codex: You've hit your usage limit. Try again in 2 hours."), .limit)
        XCTAssertEqual(trouble(nil, "Antigravity: Quota exceeded for this model."), .limit)
        // APIs, by their status and body.
        XCTAssertEqual(trouble(429, "{\"error\":{\"code\":\"insufficient_quota\"}}"), .limit)
        XCTAssertEqual(trouble(400, "Your credit balance is too low to access the API."), .limit)
        XCTAssertEqual(trouble(402, ""), .limit)
        XCTAssertEqual(trouble(429, "{\"type\":\"rate_limit_error\"}"), .rate)
        XCTAssertEqual(trouble(429, ""), .rate)
        XCTAssertEqual(trouble(529, "{\"type\":\"overloaded_error\"}"), .busy)
        XCTAssertEqual(trouble(503, "upstream down"), .busy)
        // Out of reach.
        XCTAssertEqual(trouble(nil, "LM Studio is not reachable at http://127.0.0.1:1234. Is it running?"), .unreachable)
        XCTAssertEqual(trouble(nil, "Cannot reach Ollama at http://127.0.0.1:11434. Start it with `ollama serve`."), .unreachable)
        XCTAssertEqual(trouble(nil, "Could not connect to the server."), .unreachable)
    }

    func testAnErrorAnotherModelWouldMeetToo() {
        XCTAssertNil(trouble(400, "prompt is too long: 250000 tokens > 200000 maximum"))
        XCTAssertNil(trouble(401, "invalid x-api-key"))
        XCTAssertNil(trouble(nil, "The model returned no steps."))
        XCTAssertNil(trouble(nil, "Reached the end of the file."))
    }

    func testARestLastsAsLongAsTheModelSaysOrAsTheTroubleCalls() {
        let back = Failover.trouble(status: nil, message: "Claude Code: Claude AI usage limit reached|1800007200", now: now)
        XCTAssertEqual(back?.trouble, .limit)
        XCTAssertEqual(back?.until, Date(timeIntervalSince1970: 1_800_007_200))
        // In milliseconds too.
        XCTAssertEqual(Failover.resetTime(in: "limit reached|1800007200000"), Date(timeIntervalSince1970: 1_800_007_200))
        // A time already past is no rest at all: the usual one is taken.
        let past = Failover.trouble(status: nil, message: "usage limit reached|1700000000", now: now)
        XCTAssertEqual(past?.until, now.addingTimeInterval(Failover.Trouble.limit.rest))
        XCTAssertEqual(Failover.trouble(status: 429, message: "", now: now)?.until, now.addingTimeInterval(120))
        XCTAssertNil(Failover.resetTime(in: "a | b"))
    }

    func testTheNextModelIsAsStrongAndFreeBeforeBilledThenTheStrongestOfTheRest() {
        let chosen = profile("claude-code", .account, .strong)
        let models = [
            profile("small-local", .local, .light),
            profile("api-strong", .api, .strong),
            chosen,
            profile("codex", .account, .strong),
            profile("local-strong", .local, .strong),
            profile("api-balanced", .api, .balanced),
            profile("local-balanced", .local, .balanced)
        ]
        let order = Failover.order(after: chosen.choice, among: models, resting: [])
        XCTAssertEqual(order.map(\.id), ["codex", "local-strong", "api-strong", "local-balanced", "api-balanced", "small-local"])
        // A resting model is not asked.
        let rested = Failover.order(after: chosen.choice, among: models, resting: [models[3].choice.key])
        XCTAssertEqual(rested.map(\.id), ["local-strong", "api-strong", "local-balanced", "api-balanced", "small-local"])
    }

    func testAChosenModelThatIsNotListedCountsAsBalanced() {
        let models = [profile("light", .local, .light), profile("balanced", .api, .balanced),
                      profile("strong", .api, .strong)]
        let order = Failover.order(after: ModelChoice(engine: "gone", model: "x"), among: models, resting: [])
        XCTAssertEqual(order.map(\.id), ["balanced", "strong", "light"])
    }

    func testARunStandsInOnlyWithAModelAsAbleAndNoCostlier() {
        let chosen = profile("fable", .account, .strong)
        let models = [
            profile("api-strong", .api, .strong),
            chosen,
            profile("local-balanced", .local, .balanced),
            profile("opus", .account, .strong)
        ]
        XCTAssertEqual(Failover.standIn(for: chosen, among: models, resting: [])?.id, "opus")
        // With that one resting too, none is as able and as free: the task waits.
        XCTAssertNil(Failover.standIn(for: chosen, among: models, resting: [models[3].choice.key]))
        // A task given a model billed by use may stand in with any as able.
        let billed = models[0]
        XCTAssertEqual(Failover.standIn(for: billed, among: models, resting: [models[3].choice.key])?.id, "fable")
    }

    func testAWindowOfOneModelKeepsOnlyThatModel() {
        XCTAssertEqual(Failover.windowModel("seven_day_opus"), "opus")
        XCTAssertEqual(Failover.windowModel("seven_day_fable"), "fable")
        XCTAssertNil(Failover.windowModel("seven_day"))
        XCTAssertNil(Failover.windowModel("five_hour"))
        XCTAssertNil(Failover.windowModel("primary"))
        let tool = ["", "", "Fable 5.2 · Most capable", "opus", "", "Opus 5.5 · For complex work", "fable", "", ""]
        // The whole plan's window keeps every model.
        XCTAssertTrue(Failover.window("seven_day", keeps: ["opus", "", ""], toolNames: tool))
        // One model's window keeps that model only.
        XCTAssertTrue(Failover.window("seven_day_fable", keeps: ["fable", "", ""], toolNames: tool))
        XCTAssertFalse(Failover.window("seven_day_fable", keeps: ["opus", "", "Opus 5.5 · For complex work"],
                                       toolNames: tool))
        // The tool's own pick: kept when what it is names that model, or nothing is known of it.
        XCTAssertTrue(Failover.window("seven_day_fable", keeps: ["", "", "Fable 5.2 · Most capable"], toolNames: tool))
        XCTAssertFalse(Failover.window("seven_day_fable", keeps: ["", "", "Opus 5.5 · For complex work"],
                                       toolNames: tool))
        XCTAssertTrue(Failover.window("seven_day_fable", keeps: ["", "", ""], toolNames: tool))
        // A window naming no model the tool is known to have is the whole plan's.
        XCTAssertTrue(Failover.window("seven_day_oauth_apps", keeps: ["opus", "", ""], toolNames: tool))
    }
}

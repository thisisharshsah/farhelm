import Foundation

/// Facts that are only true right now: the weather, and what a quick web
/// search says about news, scores and prices. A model has none of these on
/// its own and will make them up if asked, so they are looked up first and
/// handed to it with the question.
enum LiveFacts {
    /// Added to the instructions of every answer, with or without a lookup.
    static let rule = """


    Live facts: the weather, the time somewhere, prices, scores and news change by the minute and you cannot know them. State one only when it appears under "Live information" below or in the conversation itself. When it is not there, say in one short sentence that you could not check it. Never invent a figure, and never promise to go and check.
    """

    /// What was found for `text`, as a block to add to the request, or ""
    /// when it asks for nothing live or the lookup failed.
    static func lookup(for text: String) async -> String {
        var found: [String] = []
        // Where the Mac is, when the user has allowed it and the question
        // turns on it.
        var here: LocationService.Place?
        let named = asksWeather(text) ? place(in: text) : nil
        if asksWhere(text) || (asksWeather(text) && named == nil) {
            here = await LocationService.shared.current()
        }
        if asksWhere(text) {
            if let here {
                found.append("My location, from this Mac: \(here.label) "
                    + String(format: "(latitude %.4f, longitude %.4f).", here.latitude, here.longitude))
            } else {
                found.append("My location is not available: location access is off in Companion's Settings (Screen > Privacy) or in macOS. Say so, and say it can be turned on there.")
            }
        }
        if asksWeather(text) {
            if let report = await weather(for: named, here: named == nil ? here : nil) {
                found.append(report)
            }
        } else if let query = webQuery(in: text) {
            if let results = await web(query) {
                found.append("Web search for \"\(query)\":\n\(results)")
            }
        }
        guard !found.isEmpty else { return "" }
        return "\n\n## Live information, fetched just now\n" + found.joined(separator: "\n\n")
    }

    // MARK: Weather

    private static func asksWeather(_ text: String) -> Bool {
        matches(text, "\\b(weather|temperature|forecast|raining|snowing|umbrella|degrees outside|how (hot|cold|warm))\\b")
    }

    private static func asksWhere(_ text: String) -> Bool {
        matches(text, "\\b(my (exact |current )?location|where am i|where i am|near me|nearby|around here)\\b")
    }

    /// The place being asked about: the one named most recently, either
    /// after the weather ("weather in Boston") or as where the speaker is
    /// ("I'm in New Jersey"). nil when none is named.
    private static func place(in text: String) -> String? {
        let patterns = [
            "(?:weather|temperature|forecast)[^.?!]{0,40}?\\b(?:in|at|for|around)\\s+([A-Z][A-Za-z.'\\- ]{1,40})",
            "\\bI(?:'m| am|’m) (?:currently |right now )?(?:in|at)\\s+([A-Z][A-Za-z.'\\- ]{1,40})",
        ]
        var best: (at: Int, name: String)?
        let whole = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: whole) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                var name = String(text[range])
                // Stop at the words that follow a place rather than name it.
                for stop in [" right now", " today", " tonight", " tomorrow", " now", " and ", " but ", " so ", " can ", " please"] {
                    if let cut = name.range(of: stop, options: .caseInsensitive) {
                        name = String(name[..<cut.lowerBound])
                    }
                }
                name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .,-"))
                if name.count >= 2, match.range.location >= (best?.at ?? -1) {
                    best = (match.range.location, name)
                }
            }
        }
        return best?.name
    }

    /// The weather now and today's range, from wttr.in. With no place it
    /// goes by the network's rough location.
    private static func weather(for place: String?, here: LocationService.Place?) async -> String? {
        // A named place first, then where the Mac is, then the network's
        // rough idea of it.
        let spot = place ?? here.map { String(format: "%.3f,%.3f", $0.latitude, $0.longitude) } ?? ""
        let key = "weather:" + spot
        if let cached = cached(key) { return cached }
        let path = spot.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard let url = URL(string: "https://wttr.in/\(path)?format=j1"),
              let data = await get(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let now = (json["current_condition"] as? [[String: Any]])?.first else { return nil }

        func value(_ item: [String: Any]?, _ name: String) -> String {
            item?[name] as? String ?? ""
        }
        func first(_ item: [String: Any]?, _ name: String) -> String {
            ((item?[name] as? [[String: Any]])?.first?["value"] as? String) ?? ""
        }
        let area = (json["nearest_area"] as? [[String: Any]])?.first
        var whereIs = [first(area, "areaName"), first(area, "region")].filter { !$0.isEmpty }.joined(separator: ", ")
        if let here, !here.name.isEmpty { whereIs = here.name }
        let today = (json["weather"] as? [[String: Any]])?.first
        var lines = [
            "Weather for \(whereIs.isEmpty ? (place ?? "here") : whereIs)"
                + (place != nil ? ""
                    : (here != nil ? " (this Mac's location)"
                        : " (located roughly, from the network; say so if the place matters)")) + ":",
            "Now: \(first(now, "weatherDesc")), \(value(now, "temp_F"))°F (\(value(now, "temp_C"))°C), "
                + "feels like \(value(now, "FeelsLikeF"))°F, humidity \(value(now, "humidity"))%, "
                + "wind \(value(now, "windspeedMiles")) mph.",
        ]
        if let today {
            lines.append("Today: high \(value(today, "maxtempF"))°F (\(value(today, "maxtempC"))°C), "
                + "low \(value(today, "mintempF"))°F (\(value(today, "mintempC"))°C).")
        }
        let report = lines.joined(separator: "\n")
        remember(key, report)
        return report
    }

    // MARK: Web

    /// The question to search the web for, when it is about something that
    /// only a fresh look can answer.
    private static func webQuery(in text: String) -> String? {
        guard matches(text, "\\b(latest|news|headlines?|score|who won|stock price|share price|price of|exchange rate|trending)\\b") else {
            return nil
        }
        // The last sentence that carries the ask.
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".?!\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let asking = sentences.last {
            matches($0, "\\b(latest|news|headlines?|score|who won|stock price|share price|price of|exchange rate|trending)\\b")
        }
        guard let asking, asking.count >= 8 else { return nil }
        return String(asking.prefix(140))
    }

    private static func web(_ query: String) async -> String? {
        let key = "web:" + query.lowercased()
        if let cached = cached(key) { return cached }
        let outcome = await AgentTools.search(web: query)
        guard outcome.ok else { return nil }
        let text = String(outcome.text.prefix(1800))
        remember(key, text)
        return text
    }

    // MARK: Plumbing

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("curl/8.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    // A reply is redrafted several times as someone speaks; the same lookup
    // is not repeated for each draft.
    private static let lock = NSLock()
    private static var cache: [String: (at: Date, text: String)] = [:]

    private static func cached(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[key], Date().timeIntervalSince(entry.at) < 300 else { return nil }
        return entry.text
    }

    private static func remember(_ key: String, _ text: String) {
        lock.lock()
        defer { lock.unlock() }
        cache[key] = (Date(), text)
    }
}

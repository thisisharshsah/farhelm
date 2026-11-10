import Foundation

/// What kind of conversation this is. One tap sets how replies are written
/// and how the conversation is written up afterwards.
enum SessionMode: String, CaseIterable, Identifiable {
    case everyday, interview, lecture, workCall

    var id: String { rawValue }

    /// The mode in effect, readable from anywhere.
    static var current: SessionMode {
        SessionMode(rawValue: UserDefaults.standard.string(forKey: "sessionMode") ?? "") ?? .everyday
    }

    var label: String {
        switch self {
        case .everyday: return "Everyday"
        case .interview: return "Interview"
        case .lecture: return "Class"
        case .workCall: return "Work call"
        }
    }

    var icon: String {
        switch self {
        case .everyday: return "bubble.left.and.bubble.right"
        case .interview: return "person.crop.rectangle"
        case .lecture: return "graduationcap"
        case .workCall: return "briefcase"
        }
    }

    var summary: String {
        switch self {
        case .everyday: return "General conversations. Short, natural replies."
        case .interview: return "You are the candidate. Answers come from your own background, with a concrete example."
        case .lecture: return "You are in a class. Explains what was just covered and answers questions put to the class."
        case .workCall: return "Meetings and client calls. Concise, factual, with a clear next step."
        }
    }

    /// Added to the instructions for spoken reply suggestions.
    var replyGuidance: String {
        switch self {
        case .everyday:
            return ""
        case .interview:
            return "\nThis is a job interview and Me is the candidate. Answer in the first person from Me's real background in the details. Lead with the direct answer, then one concrete example with what Me did and the result when the question calls for it. 3 to 6 sentences. Never invent experience, numbers or employers that are not in the details; if the details do not cover it, answer honestly from what is there."
        case .lecture:
            return "\nMe is a student in a class and the other voice is usually the lecturer. If a question is put to the class, give the answer with the key step of reasoning. Otherwise explain the idea just covered in one or two plain sentences Me could say or note down."
        case .workCall:
            return "\nThis is a work or client call. Be concise and professional, use the facts in the details (product, pricing, commitments), and end with a clear next step when one is called for. Do not promise anything the details do not support."
        }
    }

    /// Added to the instructions for typed questions and screen answers.
    var askGuidance: String {
        switch self {
        case .everyday:
            return ""
        case .interview:
            return "\nContext: Me is in a job interview. For a technical or coding question, give the approach in a sentence, then the answer or code, then the complexity or trade-off an interviewer would ask about."
        case .lecture:
            return "\nContext: Me is a student in a class. Explain at the level of the material, define terms the first time, and show the working for anything computed."
        case .workCall:
            return "\nContext: Me is on a work or client call. Keep to facts Me can state with confidence."
        }
    }

    /// Added to the instructions for the notes written after the conversation.
    var notesGuidance: String {
        switch self {
        case .everyday:
            return ""
        case .interview:
            return "\nThis was a job interview with Me as the candidate. Use these sections instead of topic headings: Questions asked (each with a one-line account of how Me answered), What went well, What to improve next time, Things to follow up (who to thank, what was promised, next steps and dates)."
        case .lecture:
            return "\nThis was a class. Write study notes: Key concepts (each with a short definition), Formulas and methods, Worked examples, Assignments and deadlines, Things to review."
        case .workCall:
            return "\nThis was a work or client call. Be exact about commitments: who agreed to what and by when, plus risks or blockers raised."
        }
    }
}

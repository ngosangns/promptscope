import PromptscopeKit
import SwiftUI
import NSShell

extension Theme {
    static func agent(_ source: AgentSource) -> Color {
        switch source {
        case .grok: brandB
        case .kiroIDE: brandA
        case .kiroCLI: Color(red: 0.08, green: 0.55, blue: 0.62)
        case .omp: Color(red: 0.86, green: 0.45, blue: 0.18)
        case .pi: Color(red: 0.48, green: 0.36, blue: 0.86)
        case .devin: Color(red: 0.20, green: 0.45, blue: 0.82)
        }
    }

    static func color(_ kind: SliceKind) -> Color {
        switch kind {
        case .system: Color(red: 0.27, green: 0.40, blue: 0.72)
        case .skills: Color(red: 0.12, green: 0.52, blue: 0.46)
        case .mcp: Color(red: 0.78, green: 0.42, blue: 0.18)
        case .rules: Color(red: 0.46, green: 0.36, blue: 0.66)
        case .toolDefs: Color(red: 0.36, green: 0.42, blue: 0.48)
        case .user: Color(red: 0.20, green: 0.45, blue: 0.74)
        case .assistant: Color(red: 0.22, green: 0.52, blue: 0.34)
        case .toolResult: Color(red: 0.70, green: 0.28, blue: 0.26)
        case .reasoning: Color(red: 0.48, green: 0.48, blue: 0.50)
        case .steering: Color(red: 0.55, green: 0.40, blue: 0.22)
        case .other: Color(red: 0.55, green: 0.55, blue: 0.56)
        }
    }
}

import Foundation

enum Tool: Int, CaseIterable {
    case pen         // soft round stroke
    case eraser      // paints background color
    case line
    case rect
    case ellipse
    case fill        // paint bucket
    case text
    case select      // rectangular marquee

    var label: String {
        switch self {
        case .pen: return "✏️"
        case .eraser: return "🧽"
        case .line: return "／"
        case .rect: return "▢"
        case .ellipse: return "◯"
        case .fill: return "🪣"
        case .text: return "A"
        case .select: return "⬚"
        }
    }

    var tooltip: String {
        switch self {
        case .pen: return "Pen"
        case .eraser: return "Eraser"
        case .line: return "Line"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .fill: return "Fill"
        case .text: return "Text"
        case .select: return "Select"
        }
    }
}

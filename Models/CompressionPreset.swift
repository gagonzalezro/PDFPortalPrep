import Foundation

/// User-facing compression presets. Replaces the previous 4-level enum
/// (`official/balanced/reduced/strong`) which the UI exposed as only 3 radios
/// with a confusing mapping.
///
/// Each preset defines a DPI "ladder": the engine starts at the first (highest
/// quality) rung and only steps down toward the floor when it must to reach the
/// target size. The automatic escalation is bounded to `floorDPI` for the
/// *selected* preset — it never silently crosses into a more aggressive preset's
/// territory. Reaching the floor without meeting the target produces a visible
/// warning instead of a quietly unreadable document.
enum CompressionPreset: String, CaseIterable, Identifiable {
    /// Preserve high readability and image quality. Floor stays at a DPI where
    /// scanned text remains legible.
    case light
    /// Strong reduction for normal email/upload use.
    case balanced
    /// Aggressive reduction. Always carries a visible quality warning.
    case maximum

    var id: String { rawValue }

    /// DPI rungs tried in order, highest quality first. The last element equals
    /// `floorDPI`.
    var dpiLadder: [Int] {
        switch self {
        case .light:    return [220, 180, 150]
        case .balanced: return [150, 130, 110]
        case .maximum:  return [110, 90, 72]
        }
    }

    /// Lowest DPI the automatic escalation is allowed to reach for this preset.
    var floorDPI: Int { dpiLadder.last ?? 150 }

    /// JPEG quality (0...1) handed to the image re-encoder.
    var jpegQuality: Double {
        switch self {
        case .light:    return 0.85
        case .balanced: return 0.72
        case .maximum:  return 0.55
        }
    }

    /// Maximum always degrades aggressively, so its warning is mandatory and
    /// shown regardless of the achieved result.
    var alwaysWarnsAboutQuality: Bool { self == .maximum }

    /// Full radio-button label.
    var label: String {
        switch self {
        case .light:    return "Ligera — máxima legibilidad e imágenes"
        case .balanced: return "Balanceada — recomendada para email/subidas"
        case .maximum:  return "Máxima — reducción agresiva (puede afectar la calidad)"
        }
    }

    /// Short label for compact contexts.
    var shortLabel: String {
        switch self {
        case .light:    return "Ligera"
        case .balanced: return "Balanceada"
        case .maximum:  return "Máxima"
        }
    }
}

/// Estimated visual-quality impact of a compression result, derived from the DPI
/// actually applied. This is an *estimate* for the UI, not a measured metric.
enum VisualQualityImpact: String {
    case none
    case low
    case medium
    case high

    /// Maps the applied DPI to an impact bucket. `nil` DPI means no recompression
    /// happened (original was kept), so the impact is `none`.
    static func estimate(forAppliedDPI dpi: Int?) -> VisualQualityImpact {
        guard let dpi else { return .none }
        switch dpi {
        case 150...:      return .low
        case 110..<150:   return .medium
        default:          return .high
        }
    }

    var label: String {
        switch self {
        case .none:   return "Sin recompresión (no se modificaron las imágenes)"
        case .low:    return "Impacto visual estimado: bajo"
        case .medium: return "Impacto visual estimado: medio"
        case .high:   return "Impacto visual estimado: alto"
        }
    }
}

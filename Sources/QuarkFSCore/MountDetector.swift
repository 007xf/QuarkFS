import Foundation

public enum MountPresence: Equatable, Sendable {
    case unknown
    case none
    case quark
    case conflict
}

/// Parses the output of macOS `/sbin/mount` without assuming a particular
/// filesystem implementation. Keeping this parser in the core target makes
/// the stale-mount behavior testable without mounting a real filesystem.
public enum MountDetector {
    public static func presence(output: String, path: String) -> MountPresence {
        guard let line = mountLine(output: output, path: path) else { return .none }
        let lowercased = line.lowercased()
        let source = lowercased.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        let isQuarkSource = source == "quark:" || (source.hasPrefix("quark{") && source.hasSuffix("}:"))
        let isMacFUSE = lowercased.contains("(macfuse,") || lowercased.contains("(macfuse)")
        return isQuarkSource && isMacFUSE ? .quark : .conflict
    }

    public static func isMounted(output: String, path: String) -> Bool {
        presence(output: output, path: path) == .quark
    }

    private static func mountLine(output: String, path: String) -> String? {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let escapedPath = normalizedPath.replacingOccurrences(of: " ", with: "\\040")
        let markers = [" on \(normalizedPath)", " on \(escapedPath)"]

        return output.split(whereSeparator: \.isNewline).lazy.map(String.init).first { line in
            return markers.contains { marker in
                guard let markerRange = line.range(of: marker) else { return false }
                let suffix = line[markerRange.upperBound...]
                return suffix.isEmpty || suffix.hasPrefix(" (")
            }
        }
    }
}

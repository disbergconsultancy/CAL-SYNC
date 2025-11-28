import Foundation

/// Utilities for handling NoMas block markers
/// These markers are embedded in event notes to identify synced blocks and prevent sync loops
public struct BlockMarker {
    
    /// Marker prefix to identify synced blocks
    public static let prefix = "<!-- CALSYNC:BLOCK:"
    public static let suffix = " -->"
    
    /// Check if notes contain a NoMas block marker
    /// - Parameter notes: The event notes to check
    /// - Returns: True if the notes contain a NoMas marker
    public static func containsMarker(_ notes: String?) -> Bool {
        guard let notes = notes else { return false }
        return notes.contains(prefix)
    }
    
    /// Parse the block ID from notes containing a marker
    /// - Parameter notes: The event notes to parse
    /// - Returns: The block ID (sourceCalendarId:sourceEventId) or nil if invalid
    public static func parseBlockId(from notes: String?) -> String? {
        guard let notes = notes,
              let startRange = notes.range(of: prefix),
              let endRange = notes.range(of: suffix, range: startRange.upperBound..<notes.endIndex) else {
            return nil
        }
        
        let markerContent = String(notes[startRange.upperBound..<endRange.lowerBound])
        let components = markerContent.split(separator: ":")
        var sourceId: String?
        var eventId: String?
        
        for component in components {
            if component.hasPrefix("source=") {
                sourceId = String(component.dropFirst(7))
            } else if component.hasPrefix("id=") {
                eventId = String(component.dropFirst(3))
            }
        }
        
        if let sourceId = sourceId, let eventId = eventId {
            return generateBlockId(sourceCalendarId: sourceId, sourceEventId: eventId)
        }
        return nil
    }
    
    /// Generate a stable block ID from source calendar and event IDs
    /// - Parameters:
    ///   - sourceCalendarId: The ID of the source calendar
    ///   - sourceEventId: The ID of the source event
    /// - Returns: A combined block ID string
    public static func generateBlockId(sourceCalendarId: String, sourceEventId: String) -> String {
        return "\(sourceCalendarId):\(sourceEventId)"
    }
    
    /// Create a marker string to embed in event notes
    /// - Parameters:
    ///   - sourceCalendarId: The ID of the source calendar
    ///   - sourceEventId: The ID of the source event
    /// - Returns: The complete marker string
    public static func createMarker(sourceCalendarId: String, sourceEventId: String) -> String {
        return "\(prefix)source=\(sourceCalendarId):id=\(sourceEventId)\(suffix)"
    }
}

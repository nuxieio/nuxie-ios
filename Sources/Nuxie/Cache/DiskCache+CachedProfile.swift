import Foundation

// Make DiskCache conform to CachedProfileStore when T == CachedProfile
extension DiskCache: CachedProfileStore where T == CachedProfile {}
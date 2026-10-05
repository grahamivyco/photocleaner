import Foundation

enum Config {
    /// Where the System Photo Library lives. Shoebox won't review or delete
    /// anything unless this path exists, so an unplugged drive is always safe.
    /// If the library moves, change this one line.
    static let libraryPath = "/Volumes/Photos/Photos Library.photoslibrary"

    /// How far a two-finger trackpad swipe must travel (in points) to count.
    static let swipeThreshold: CGFloat = 120

    /// After this many seconds without an answer, explain that Photos is busy.
    static let slowPhotosSeconds = 20

    /// Oldest year in the year picker.
    static let earliestGuessYear = 2000

    /// Pixel size requested for the full-screen preview.
    static let previewPixels = CGSize(width: 2400, height: 2400)
}

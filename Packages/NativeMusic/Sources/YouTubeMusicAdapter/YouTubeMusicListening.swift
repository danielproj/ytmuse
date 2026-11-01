import Domain

/// YouTube Music's listening rule as this adapter defines it for the app's LOCAL history: a track counts once the listener has
/// heard half of it or 30 seconds, whichever is less. This is the app's own record. YouTube's own player records YouTube Music's
/// history by YouTube's rules, and the app never writes or imitates it.
public enum YouTubeMusicListening {
    public static let policy = ListeningPolicy(maximumSeconds: 30, fractionOfDuration: 0.5, seekTolerance: 1.5)
}

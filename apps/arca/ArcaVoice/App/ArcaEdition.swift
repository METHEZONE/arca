import Foundation

/// Which ARCA this binary is. The Beta edition is the same code with the
/// heavy and experimental surfaces switched off, so testers get the four
/// things that must work — brain, recording+notes, day report, wiki — and
/// nothing that can fall over in front of them.
enum ArcaEdition {
    static var isBeta: Bool {
        #if ARCA_BETA
        return true
        #else
        return false
        #endif
    }

    static var isTest: Bool {
        #if ARCA_TEST_BUILD
        return true
        #else
        return false
        #endif
    }

    /// Application Support folder for this edition's data.
    static var dataFolderName: String {
        #if ARCA_TEST_BUILD
        return "ArcaVoiceTest"
        #elseif ARCA_BETA
        return "ArcaVoiceBeta"
        #else
        return "ArcaVoice"
        #endif
    }
}

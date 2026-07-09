import Foundation

public enum UserFacingError {
    public static func message(for error: Error) -> String {
        if let urlError = error as? URLError {
            return message(for: urlError)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return message(for: URLError(URLError.Code(rawValue: nsError.code)))
        }
        if nsError.domain == NSPOSIXErrorDomain || nsError.domain == NSCocoaErrorDomain {
            if nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError {
                return "ARCA needs permission to read or write this file. Choose the file again or allow access in Settings."
            }
        }
        return error.localizedDescription
    }

    private static func message(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "ARCA is offline or the network is blocked. Check your connection and try again."
        case .timedOut:
            return "The AI request timed out. Check your connection and try again."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return "ARCA could not make a secure connection. Check your network settings and try again."
        default:
            return error.localizedDescription
        }
    }
}

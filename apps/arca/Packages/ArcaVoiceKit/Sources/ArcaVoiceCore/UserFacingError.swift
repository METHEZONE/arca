import Foundation

/// Turns the errors ARCA actually hits into one sentence about what happened
/// and one about what to do — in the user's language. A raw provider JSON
/// blob ("Your credit balance is too low…", `invalid x-api-key`) tells the
/// user nothing about which knob to turn; this does.
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
                return L("ARCA가 이 파일을 읽거나 쓸 권한이 없어요. 파일을 다시 선택하거나 설정에서 접근을 허용해 주세요.",
                         "ARCA needs permission to read or write this file. Choose the file again or allow access in Settings.")
            }
        }
        return message(forDescription: error.localizedDescription)
    }

    /// Provider error text (Anthropic/OpenAI/Composio bodies, HTTP codes) →
    /// what it means and what fixes it.
    public static func message(forDescription raw: String) -> String {
        let text = raw.lowercased()

        // Anthropic
        if text.contains("credit balance is too low") {
            return L("Anthropic 크레딧이 다 떨어졌어요. console.anthropic.com › Plans & Billing에서 충전하거나, 설정 › AI 키에 다른 Anthropic 키를 넣어주세요.",
                     "Your Anthropic credit is used up. Top up at console.anthropic.com › Plans & Billing, or enter another Anthropic key in Settings › AI keys.")
        }
        if text.contains("invalid x-api-key") || text.contains("authentication_error") {
            return L("Anthropic 키가 잘못됐거나 폐기됐어요. 설정 › AI 키에서 키를 다시 붙여 넣어 주세요.",
                     "The Anthropic key is invalid or revoked. Paste it again in Settings › AI keys.")
        }
        if text.contains("permission_error") {
            return L("이 Anthropic 키는 이 모델을 쓸 권한이 없어요. 설정에서 모델을 바꾸거나 다른 키를 써 주세요.",
                     "This Anthropic key can't use that model. Pick another model in Settings or use a different key.")
        }
        if text.contains("rate_limit") || text.contains("http 429") || text.contains("(http 429)") {
            return L("요청이 너무 잦아요. 잠시 뒤에 다시 시도하면 돼요.",
                     "Too many requests right now. Try again in a moment.")
        }
        if text.contains("overloaded") || text.contains("http 529") || text.contains("http 503") {
            return L("AI 서버가 잠시 과부하예요. 몇 분 뒤 다시 시도해 주세요.",
                     "The AI provider is overloaded. Try again in a few minutes.")
        }
        if text.contains("not_found_error") && text.contains("model") {
            return L("설정한 모델 이름을 Anthropic이 모르는 모델이에요. 설정 › 모델에서 다른 모델을 골라 주세요.",
                     "Anthropic doesn't recognize the selected model. Pick another in Settings › Model.")
        }

        // OpenAI
        if text.contains("insufficient_quota") || text.contains("exceeded your current quota") {
            return L("OpenAI 크레딧이 다 떨어졋어요. platform.openai.com › Billing에서 충전하거나, 설정 › AI 키에 다른 OpenAI 키를 넣어주세요.",
                     "Your OpenAI credit is used up. Top up at platform.openai.com › Billing, or enter another OpenAI key in Settings › AI keys.")
                .replacingOccurrences(of: "떨어졋", with: "떨어졌")
        }
        if text.contains("incorrect api key") || text.contains("invalid_api_key") {
            return L("OpenAI 키가 잘못됐어요. 설정 › AI 키에서 키를 다시 붙여 넣어 주세요.",
                     "The OpenAI key is invalid. Paste it again in Settings › AI keys.")
        }

        // Composio / connectors
        if text.contains("composio") && (text.contains("401") || text.contains("unauthorized") || text.contains("invalid api key")) {
            return L("Composio 키가 맞지 않아요. 설정 › 커넥터에서 키를 확인해 주세요.",
                     "The Composio key isn't accepted. Check it in Settings › Connectors.")
        }
        if text.contains("no active connection") || text.contains("connected account") && text.contains("not found") {
            return L("이 앱이 아직 연결되지 않았어요. 설정 › 커넥터에서 연결해 주세요.",
                     "That app isn't connected yet. Connect it in Settings › Connectors.")
        }

        // Missing keys, as ARCA phrases them itself
        if text.contains("key is required") || text.contains("add an anthropic key") || text.contains("add one in settings") {
            return L("AI 키가 없어요. 설정 › AI 키에 Anthropic 또는 OpenAI 키를 넣어 주세요.",
                     "No AI key yet. Add an Anthropic or OpenAI key in Settings › AI keys.")
        }

        // Unknown: keep it short and strip the JSON noise.
        return String(compact(raw).prefix(220))
    }

    /// Drops the `{"type":"error",…}` wrapper when a provider body leaks through.
    private static func compact(_ raw: String) -> String {
        guard let start = raw.range(of: "\"message\":\"") else { return raw }
        let rest = raw[start.upperBound...]
        if let end = rest.range(of: "\"") {
            let inner = String(rest[..<end.lowerBound])
            if let prefixEnd = raw.range(of: "{") { return String(raw[..<prefixEnd.lowerBound]) + inner }
            return inner
        }
        return raw
    }

    private static func message(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return L("인터넷에 연결되지 않았거나 네트워크가 막혀 있어요. 연결을 확인하고 다시 시도해 주세요.",
                     "ARCA is offline or the network is blocked. Check your connection and try again.")
        case .timedOut:
            return L("AI 요청이 시간 초과됐어요. 연결을 확인하고 다시 시도해 주세요.",
                     "The AI request timed out. Check your connection and try again.")
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
            return L("보안 연결을 만들 수 없었어요. 네트워크 설정(VPN·프록시)을 확인해 주세요.",
                     "ARCA could not make a secure connection. Check your network settings (VPN/proxy).")
        default:
            return error.localizedDescription
        }
    }
}

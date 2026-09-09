import type { Metadata } from "next";
import "../arca.css";
import "../legal/legal.css";

export const metadata: Metadata = {
  title: "이용약관 — ARCA",
  description: "ARCA 서비스 이용에 관한 약관, 책임 범위, 이용자 의무를 안내합니다.",
};

export default function TermsPage() {
  return (
    <div className="arca-root legal-root">
      <div className="legal-card">
        <a className="legal-back" href="/arca">
          ← ARCA
        </a>
        <h1>이용약관</h1>
        <p className="legal-meta">시행일: 2026년 9월 10일</p>

        <p>
          본 약관은 더존바이오(THE ZONE BIO, Inc.)가 제공하는 ARCA 서비스 이용에 적용됩니다. 문의:{" "}
          <a href="mailto:me@thezonebio.com">me@thezonebio.com</a>
        </p>

        <h2>서비스 설명</h2>
        <p>
          ARCA는 AI 컴패니언 서비스입니다. AI 응답은 실수를 할 수 있으므로, 중요한 결정이나 조치 전에는 반드시
          직접 확인하시기 바랍니다.
        </p>

        <h2>계정 책임</h2>
        <p>이용자는 자신의 계정 정보와 연결된 서비스(Google, Slack 등)의 보안을 유지할 책임이 있습니다.</p>

        <h2>이용자 의무</h2>
        <ul>
          <li>법령을 위반하는 목적으로 서비스를 이용할 수 없습니다.</li>
          <li>본인이 아닌 타인의 연결된 계정을 악용할 수 없습니다.</li>
        </ul>

        <h2>베타 서비스 및 가용성</h2>
        <p>
          ARCA는 베타 단계로 제공되며 기능·가용성이 예고 없이 변경될 수 있습니다. 서비스 중단에 대해 어떠한
          보장도 하지 않습니다.
        </p>

        <h2>책임 제한</h2>
        <p>관련 법령이 허용하는 최대 범위에서, 회사는 서비스 이용으로 발생한 손해에 대해 책임을 지지 않습니다.</p>

        <h2>준거법</h2>
        <p>본 약관은 대한민국 법령에 따라 해석됩니다.</p>

        <h2>문의</h2>
        <p>
          이용약관 관련 문의는 <a href="mailto:me@thezonebio.com">me@thezonebio.com</a>로 연락해 주세요.
        </p>

        <hr className="legal-divider" />

        <h1>Terms of Service</h1>
        <p className="legal-meta">Effective date: September 10, 2026</p>

        <p>
          These terms govern your use of ARCA, provided by THE ZONE BIO, Inc. (더존바이오). Contact:{" "}
          <a href="mailto:me@thezonebio.com">me@thezonebio.com</a>
        </p>

        <h2>Service description</h2>
        <p>
          ARCA is an AI companion. It may make mistakes — verify before acting on important matters.
        </p>

        <h2>Account responsibilities</h2>
        <p>You&apos;re responsible for keeping your account and connected accounts (Google, Slack, etc.) secure.</p>

        <h2>Acceptable use</h2>
        <ul>
          <li>No unlawful use of the service.</li>
          <li>No abuse of connected accounts belonging to others.</li>
        </ul>

        <h2>Beta status and availability</h2>
        <p>
          ARCA is provided in beta. Features and availability may change without notice, and we make no
          guarantee against interruptions.
        </p>

        <h2>Limitation of liability</h2>
        <p>To the extent permitted by law, we are not liable for damages arising from your use of the service.</p>

        <h2>Governing law</h2>
        <p>These terms are governed by the laws of the Republic of Korea.</p>

        <h2>Contact</h2>
        <p>
          Questions about these terms: <a href="mailto:me@thezonebio.com">me@thezonebio.com</a>
        </p>
      </div>
    </div>
  );
}

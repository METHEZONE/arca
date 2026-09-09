import type { Metadata } from "next";
import "../arca.css";
import "../legal/legal.css";

export const metadata: Metadata = {
  title: "개인정보처리방침 — ARCA",
  description: "ARCA가 수집하는 정보, 사용 목적, 제3자 공유, 보관 및 삭제 방법을 안내합니다.",
};

export default function PrivacyPage() {
  return (
    <div className="arca-root legal-root">
      <div className="legal-card">
        <a className="legal-back" href="/arca">
          ← ARCA
        </a>
        <h1>개인정보처리방침</h1>
        <p className="legal-meta">시행일: 2026년 9월 10일</p>

        <p>
          더존바이오(THE ZONE BIO, Inc.)는 ARCA 서비스(이하 &ldquo;ARCA&rdquo;)를 운영하며, 이용자의 개인정보를
          아래와 같이 처리합니다. 문의: <a href="mailto:me@thezonebio.com">me@thezonebio.com</a>
        </p>

        <h2>수집하는 정보</h2>
        <ul>
          <li>
            <b>구글 로그인</b> — 계정 생성을 위해 이메일 주소만 수집합니다 (openid, email 권한).
          </li>
          <li>
            <b>메모리</b> — 이용자 또는 앱이 저장한 짧은 사실 정보로, 대화·회의 요약에서 추출됩니다. ARCA
            서버(Supabase, 서울 리전)에 계정 단위로 저장됩니다.
          </li>
          <li>
            <b>커넥터 데이터</b> — Gmail, Google Calendar, Slack 등은 이용자가 직접 연결한 계정을 통해서만
            접근하며, 요청한 작업 수행에 필요한 범위 이상으로 보관하지 않습니다.
          </li>
          <li>
            <b>기기 식별자</b> — 계정과 기기를 연결하기 위해 수집합니다.
          </li>
          <li>
            <b>이용 지표</b> — 횟수, 시각, 토큰 수 등 계량 정보만 수집하며 대화 내용은 포함하지 않습니다.
          </li>
        </ul>

        <h2>기기에만 남는 정보</h2>
        <p>
          회의 음성, 전사본, 노트, Apple Health 데이터는 이용자의 기기에서 처리되며 ARCA 서버로 업로드되지
          않습니다.
        </p>

        <h2>제3자 제공</h2>
        <ul>
          <li>Anthropic(Claude 모델) — 응답 생성을 위해 대화 내용과 메모리 컨텍스트를 전달받습니다.</li>
          <li>OpenAI — 설정에 따라 전사·분석에 사용될 수 있습니다.</li>
          <li>Composio — 커넥터 OAuth를 중개합니다.</li>
          <li>Vercel — 서비스 호스팅.</li>
          <li>Supabase — 데이터베이스 호스팅.</li>
        </ul>
        <p>
          Google 사용자 데이터는 Google API Services User Data Policy(Limited Use 포함)를 준수하여 처리됩니다.
        </p>

        <h2>보관 및 삭제</h2>
        <p>
          이용자는 앱 내에서 언제든 메모리를 삭제할 수 있습니다. 계정 삭제 및 전체 데이터 내보내기는{" "}
          <a href="mailto:me@thezonebio.com">me@thezonebio.com</a>로 요청하면 30일 이내 처리됩니다.
        </p>

        <h2>보안</h2>
        <p>전송 구간은 TLS로 암호화되며, 저장 데이터는 호스팅 제공업체의 저장 암호화를 적용합니다.</p>

        <h2>아동 보호</h2>
        <p>ARCA는 만 14세 미만 이용자를 대상으로 하지 않습니다.</p>

        <h2>정책 변경</h2>
        <p>정책이 변경되면 이 페이지에 변경일과 함께 게시합니다.</p>

        <hr className="legal-divider" />

        <h1>Privacy Policy</h1>
        <p className="legal-meta">Effective date: September 10, 2026</p>

        <p>
          THE ZONE BIO, Inc. (더존바이오) operates ARCA. Contact:{" "}
          <a href="mailto:me@thezonebio.com">me@thezonebio.com</a>
        </p>

        <h2>What we collect</h2>
        <ul>
          <li>
            <b>Google sign-in</b> — email address only (openid, email scopes), to create your account.
          </li>
          <li>
            <b>Memories</b> — short text facts extracted from your chats and meeting summaries, saved by you or
            the app, stored on the ARCA server (Supabase, Seoul region) scoped to your account.
          </li>
          <li>
            <b>Connector data</b> — Gmail, Google Calendar, Slack, etc. are accessed only through your own
            connected accounts to perform actions you ask for, and are not stored beyond what the action needs.
          </li>
          <li>
            <b>Device identifiers</b> — used to link devices to your account.
          </li>
          <li>
            <b>Usage metering</b> — counts, timestamps, and token counts only, never content.
          </li>
        </ul>

        <h2>What stays on your device</h2>
        <p>Meeting audio, transcripts, notes, and Apple Health data are processed on your own devices and are not uploaded to ARCA servers.</p>

        <h2>Third parties</h2>
        <ul>
          <li>Anthropic (Claude model) receives conversation text and memory context to generate replies.</li>
          <li>OpenAI may be used for transcription/analysis when configured.</li>
          <li>Composio brokers connector OAuth.</li>
          <li>Vercel hosts the service.</li>
          <li>Supabase hosts the database.</li>
        </ul>
        <p>Google user data is handled per the Google API Services User Data Policy, including Limited Use requirements.</p>

        <h2>Retention and deletion</h2>
        <p>
          You can delete memories in the app any time. Account deletion and full data export are available on
          request to <a href="mailto:me@thezonebio.com">me@thezonebio.com</a>, processed within 30 days.
        </p>

        <h2>Security</h2>
        <p>TLS in transit; encrypted at rest by our hosting providers. Credentials are never shown to the model.</p>

        <h2>Children</h2>
        <p>ARCA is not directed to children under 14 (Korea) / 13 (elsewhere).</p>

        <h2>Changes</h2>
        <p>We&apos;ll post updates to this page with the date they take effect.</p>
      </div>
    </div>
  );
}

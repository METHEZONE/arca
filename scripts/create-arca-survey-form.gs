/**
 * ARCA 사용자 설문 — Google Form 자동 생성기
 *
 * 사용법:
 *  1) script.google.com 접속 (me@thezonebio.com 로그인 상태)
 *  2) 새 프로젝트 > 이 코드 전체 붙여넣기
 *  3) createArcaSurvey 함수 실행 > 권한 1회 허용
 *  4) 실행 로그(보기 > 로그)에 편집/응답 URL 출력됨
 *
 * 설계 원칙: 미래 가정("쓰실래요?") 금지, 과거의 실제 행동을 캐는 질문 위주.
 */
function createArcaSurvey() {
  var form = FormApp.create('ARCA 사용자 설문 — 회의/대화 기록, 정말 누가 왜 하는가')
    .setDescription(
      '솔직한 "실제 경험" 한 줄이 가장 큰 도움이 됩니다. 약 3분 소요.\n' +
      '※ 멋진 답보다 "지난번에 진짜로 어떻게 했는지"가 중요합니다.')
    .setProgressBar(true)
    .setCollectEmail(false);

  // ── 섹션 1. 누가 ──────────────────────────────
  form.addSectionHeaderItem()
    .setTitle('1. 당신의 맥락')
    .setHelpText('30초면 됩니다.');

  form.addMultipleChoiceItem()
    .setTitle('하루에 회의·통화·대화 내용을 "기록으로 남겨야 하는" 상황이 몇 번 정도 있나요?')
    .setChoiceValues(['0번', '1~2번', '3~5번', '6번 이상'])
    .setRequired(true);

  form.addMultipleChoiceItem()
    .setTitle('그 기록은 주로 "누구를 위한" 것인가요?')
    .setChoiceValues(['나만 본다', '상사·팀 보고용', '동료와 협업·공유용', '고객·외부 대상'])
    .showOtherOption(true)
    .setRequired(true);

  form.addParagraphTextItem()
    .setTitle('기록을 안 해뒀다가 곤란했던 적, 최근 한 달 안에 있었나요? 있다면 뭐였는지 한 줄로.')
    .setRequired(false);

  // ── 섹션 2. 왜 (진짜 고통) ─────────────────────
  form.addSectionHeaderItem()
    .setTitle('2. 실제로 어떻게 하고 있나요')
    .setHelpText('가장 중요한 부분입니다. "지난번 그때"를 떠올리며 답해주세요.');

  form.addParagraphTextItem()
    .setTitle('마지막으로 회의/대화 내용을 다시 찾아본 게 언제예요? 왜 찾았고, 찾는 데 얼마나 걸렸나요?')
    .setRequired(true);

  form.addCheckboxItem()
    .setTitle('지금은 회의가 끝나고 내용을 어떻게 정리하세요? (해당되는 것 모두)')
    .setChoiceValues([
      '따로 정리 안 함',
      '머리로 기억',
      '손메모·수기',
      '녹음해두고 나중에 다시 들음',
      '노션·옵시디언 등에 직접 타이핑'
    ])
    .showOtherOption(true)
    .setRequired(true);

  form.addParagraphTextItem()
    .setTitle('그 방식에서 제일 짜증나는 순간이 언제예요? (한 줄)')
    .setRequired(true);

  form.addParagraphTextItem()
    .setTitle('녹음·메모·정리 앱을 쓰다가 "그만둔" 게 있나요? 있다면 왜 그만뒀어요?')
    .setHelpText('실패 이유가 가장 솔직한 인사이트입니다.')
    .setRequired(false);

  // ── 섹션 3. 현대(보수적 조직) 특화 ─────────────
  form.addSectionHeaderItem()
    .setTitle('3. 회사에서 쓴다면')
    .setHelpText('직장에서의 현실적인 부분입니다.');

  form.addMultipleChoiceItem()
    .setTitle('회사 회의를 "자동 녹음·기록"한다고 하면, 가장 먼저 드는 걱정은?')
    .setChoiceValues([
      '보안·내용 유출',
      '상사·동료 눈치',
      '회사 정책상 금지일 듯',
      '딱히 걱정 없음'
    ])
    .showOtherOption(true)
    .setRequired(true);

  form.addMultipleChoiceItem()
    .setTitle('이런 툴을 회사에서 쓰려면 누구의 "OK"가 필요할 것 같아요?')
    .setChoiceValues([
      '그냥 나 혼자 쓰면 됨',
      '팀장 승인',
      'IT·보안팀 승인',
      '전사 정책 차원'
    ])
    .setRequired(true);

  // ── 섹션 4. 지불의사 ───────────────────────────
  form.addSectionHeaderItem()
    .setTitle('4. 마지막 한 가지');

  form.addMultipleChoiceItem()
    .setTitle('이걸 돈 내고 쓴다면, 한 달에 얼마까지면 "낼 만하다" 싶어요?')
    .setChoiceValues(['안 냄', '~5,000원', '~10,000원', '30,000원 이상'])
    .setRequired(true);

  form.addParagraphTextItem()
    .setTitle('↑ 그 금액을 고른 이유를 한 줄로.')
    .setRequired(false);

  Logger.log('✅ 폼 생성 완료');
  Logger.log('편집 URL: ' + form.getEditUrl());
  Logger.log('응답(공유) URL: ' + form.getPublishedUrl());
}

#!/bin/bash
# FaceUnlock 설치: 빌드 → /Applications 에 설치 → 로그인 시 자동 실행 등록 → 실행
set -euo pipefail
cd "$(dirname "$0")"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode 명령어 도구가 필요합니다. 아래 명령으로 설치한 뒤 이 스크립트를 다시 실행하세요."
  echo ""
  echo "  xcode-select --install"
  exit 1
fi

UPDATING=0
[ -d /Applications/FaceUnlock.app ] && UPDATING=1

./build.sh --install

echo ""
echo "메뉴 막대에 FaceUnlock 아이콘이 생겼습니다. 아이콘을 눌러 차례대로 진행하세요."
if [ "$UPDATING" = "1" ]; then
  echo ""
  echo "※ 다시 설치한 경우 이전 권한이 무효가 됩니다. 먼저 아래 명령을 실행하세요."
  echo "    tccutil reset Accessibility local.faceunlock.app"
fi
echo ""
echo "  1. 권한 요청…            카메라 허용, 손쉬운 사용에서 FaceUnlock 켜기"
echo "  2. 얼굴 등록…"
echo "  3. 인식 테스트…          다른 사람 얼굴·사진에 '불일치'가 나오는지 확인"
echo "  4. 로그인 비밀번호 저장…"
echo "  5. 얼굴 잠금해제 사용     체크"

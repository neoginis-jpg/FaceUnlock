#!/bin/bash
# FaceUnlock 과 그 데이터를 모두 지운다.
set -uo pipefail

AGENT="local.faceunlock.agent"
BUNDLE="local.faceunlock.app"

echo "다음을 삭제합니다."
echo "  - /Applications/FaceUnlock.app 과 로그인 시 자동 실행 항목"
echo "  - 등록된 얼굴 데이터"
echo "  - 키체인에 저장된 로그인 비밀번호 사본 (Mac 로그인 비밀번호 자체는 그대로입니다)"
echo "  - 설정, 권한, 로그"
read -r -p "계속할까요? [y/N] " answer
case "$answer" in
  y|Y) ;;
  *) echo "취소했습니다."; exit 0 ;;
esac

launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null
pkill -x FaceUnlock 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$AGENT.plist"
rm -rf /Applications/FaceUnlock.app
rm -rf "$HOME/Library/Application Support/FaceUnlock"
security delete-generic-password -s "$BUNDLE" -a login-password >/dev/null 2>&1
defaults delete "$BUNDLE" >/dev/null 2>&1
tccutil reset Accessibility "$BUNDLE" >/dev/null 2>&1
tccutil reset Camera "$BUNDLE" >/dev/null 2>&1
rm -f "$HOME/Library/Logs/FaceUnlock.log"

echo "삭제했습니다."

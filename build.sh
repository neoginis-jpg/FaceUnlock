#!/bin/bash
# FaceUnlock.app 을 build/ 아래에 만든다. Xcode 명령어 도구(swiftc)가 필요하다.
#   ./build.sh            빌드만
#   ./build.sh --install  빌드한 뒤 /Applications 의 앱을 교체하고 다시 실행
set -euo pipefail
cd "$(dirname "$0")"

APP="build/FaceUnlock.app"
INSTALLED="/Applications/FaceUnlock.app"
AGENT="local.faceunlock.agent"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT.plist"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework AVFoundation -framework Vision -framework QuartzCore \
  -framework CoreImage -framework Security -framework OpenDirectory \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/FaceUnlock"

# 임시(ad-hoc) 서명. 다시 빌드하면 카메라·손쉬운 사용 권한을 다시 허용하고
# 로그인 비밀번호도 다시 저장해야 한다.
codesign --force --sign - --identifier local.faceunlock.app "$APP"
echo "빌드 완료: $(pwd)/$APP"

if [ "${1:-}" = "--install" ]; then
  # 자동 실행 항목을 먼저 내려야 교체 도중에 앱이 다시 켜지지 않는다.
  launchctl bootout "gui/$(id -u)/$AGENT" 2>/dev/null || true
  pkill -x FaceUnlock 2>/dev/null || true
  sleep 1
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  rm -rf "$APP"

  # 로그인 시 자동 실행 항목. 없을 때만 만든다.
  if [ ! -f "$AGENT_PLIST" ]; then
    mkdir -p "$(dirname "$AGENT_PLIST")"
    cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AGENT</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALLED/Contents/MacOS/FaceUnlock</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
PLIST
  fi
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
  echo "설치 완료: $INSTALLED"
fi

#!/bin/zsh
# 构建 PhotoAI 并覆盖安装到 iPad（免费 Apple ID 签名 7 天到期，到期前后跑一次就好）。
# 覆盖安装保留库和预览。不要在 iPad 上删掉应用，删了数据就没了。
#
# 用法：Scripts/reinstall.sh [--launch]
#   --launch        装完直接打开
#   PHOTOAI_DEVICE  环境变量，指定设备的 UDID 或名字（默认找唯一一台配对过的 iPad）
set -euo pipefail

cd "${0:A:h}/.."
launch=false
[[ "${1:-}" == "--launch" ]] && launch=true

fail() { print -u2 "✘ $1"; exit 1; }
step() { print "▸ $1"; }

# 1. 签名配置
signing=Config/Signing.xcconfig
[[ -f $signing ]] || fail "没有 $signing：cp Config/Signing.xcconfig.example $signing，再填 Team ID 和 Bundle ID。"
team=$(sed -nE 's/^DEVELOPMENT_TEAM *= *([A-Z0-9]+).*/\1/p' $signing)
bundle_id=$(sed -nE 's/^PRODUCT_BUNDLE_IDENTIFIER *= *([^ ]+).*/\1/p' $signing)
[[ -n $team && $team != ABCDE12345 ]] || fail "$signing 里的 DEVELOPMENT_TEAM 还没填。"
[[ -n $bundle_id && $bundle_id != *xxxx ]] || fail "$signing 里的 PRODUCT_BUNDLE_IDENTIFIER 还没填。"
security find-identity -v -p codesigning | grep -q "Apple Development" \
  || fail "钥匙串里没有 Apple Development 证书：Xcode → 设置 → 账户，登录 Apple ID，选个人团队点“管理证书”加一个。"

# 2. 找 iPad
command -v jq >/dev/null || fail "需要 jq：brew install jq"
devices_json=$(mktemp)
trap 'rm -f $devices_json' EXIT
xcrun devicectl list devices --json-output $devices_json >/dev/null 2>&1 || fail "devicectl 列设备失败。"
if [[ -n ${PHOTOAI_DEVICE:-} ]]; then
  udid=$(jq -r --arg d "$PHOTOAI_DEVICE" '.result.devices[] | select(.hardwareProperties.udid == $d or .deviceProperties.name == $d) | .hardwareProperties.udid' $devices_json | head -1)
else
  udids=("${(@f)$(jq -r '.result.devices[] | select(.hardwareProperties.deviceType == "iPad" and .hardwareProperties.reality == "physical" and .connectionProperties.pairingState == "paired") | .hardwareProperties.udid' $devices_json)}")
  udids=(${udids:#})
  (( ${#udids} == 1 )) || fail "找到 ${#udids} 台配对过的 iPad。用线接上 iPad、解锁、点“信任”；有好几台时用 PHOTOAI_DEVICE=<UDID> 指定。"
  udid=$udids[1]
fi
[[ -n ${udid:-} ]] || fail "找不到设备 ${PHOTOAI_DEVICE:-}。"
name=$(jq -r --arg u "$udid" '.result.devices[] | select(.hardwareProperties.udid == $u) | .deviceProperties.name' $devices_json)
tunnel=$(jq -r --arg u "$udid" '.result.devices[] | select(.hardwareProperties.udid == $u) | .connectionProperties.tunnelState // "?"' $devices_json)
step "设备：$name（连接 $tunnel）"

info_json=$(mktemp)
trap 'rm -f $devices_json $info_json' EXIT
xcrun devicectl device info details --device $udid --json-output $info_json >/dev/null 2>&1 || true
dev_mode=$(jq -r '.result.deviceProperties.developerModeStatus // "unknown"' $info_json 2>/dev/null || echo unknown)
os_version=$(jq -r '.result.deviceProperties.osVersionNumber // "?"' $info_json 2>/dev/null || echo "?")
step "iPadOS $os_version，开发者模式 $dev_mode"
[[ $dev_mode != disabled ]] || fail "iPad 没开开发者模式：设置 → 隐私与安全性 → 开发者模式 → 打开，重启后解锁点“打开”。"

# 3. 生成工程、构建（顺带续签描述文件）
command -v xcodegen >/dev/null || fail "需要 XcodeGen：brew install xcodegen"
step "生成工程"
xcodegen generate --quiet
build_number=$(date +%Y%m%d%H%M)
log=build/xcodebuild.log
mkdir -p build
step "构建 Release（构建号 $build_number），日志 $log"
if ! xcodebuild -project PhotoAI-iPad.xcodeproj -scheme PhotoAI-iPad -configuration Release \
    -destination "id=$udid" -derivedDataPath build/DerivedData \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    CURRENT_PROJECT_VERSION=$build_number build >$log 2>&1; then
  grep -E "error:|错误" $log | sort -u | head -20 >&2 || tail -30 $log >&2
  grep -q "No Accounts" $log && fail "Xcode 里没有登录 Apple ID：Xcode → 设置 → 账户 → 左下角 + → Apple ID，登录后再跑。"
  fail "构建失败。签名出错的话：在 Xcode 里打开 PhotoAI-iPad.xcodeproj，选目标 → Signing & Capabilities 看提示（多半是没登录 Apple ID 或 Bundle ID 被占用）。"
fi
app=build/DerivedData/Build/Products/Release-iphoneos/PhotoAI.app
[[ -d $app ]] || fail "构建成功但找不到 $app。"

# 4. 安装
step "安装到 $name"
if ! xcrun devicectl device install app --device $udid $app >build/install.log 2>&1; then
  tail -20 build/install.log >&2
  fail "安装失败。iPad 要解锁；第一次装时可能要在 iPad 上确认。"
fi

# 5. 签名到期日
expiry=$(security cms -D -i $app/embedded.mobileprovision 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null || echo "?")
if [[ $expiry != "?" ]]; then
  step "装好了。签名到期：$expiry（UTC），到期前再跑一次本脚本。"
else
  step "装好了。读不到签名到期日。"
fi

if $launch; then
  step "打开应用"
  if ! xcrun devicectl device process launch --device $udid $bundle_id >build/launch.log 2>&1; then
    tail -5 build/launch.log >&2
    print "第一次装要先在 iPad 上信任开发者：设置 → 通用 → VPN 与设备管理 → 选你的 Apple ID → 信任。然后再打开。"
  fi
fi

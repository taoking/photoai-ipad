#!/bin/zsh
# 把 iPad 上 M0 的技术验证日志拷到 build/技术验证日志.txt（只读应用自己的沙盒，不碰卡）。
# 用法：Scripts/pull-log.sh   设备同 reinstall.sh：默认唯一一台配对过的 iPad，或 PHOTOAI_DEVICE=<UDID>
set -euo pipefail

cd "${0:A:h}/.."
bundle_id=$(sed -nE 's/^PRODUCT_BUNDLE_IDENTIFIER *= *([^ ]+).*/\1/p' Config/Signing.xcconfig)
devices_json=$(mktemp)
trap 'rm -f $devices_json' EXIT
xcrun devicectl list devices --json-output $devices_json >/dev/null 2>&1
udid=${PHOTOAI_DEVICE:-$(jq -r '.result.devices[] | select(.hardwareProperties.deviceType == "iPad" and .hardwareProperties.reality == "physical" and .connectionProperties.pairingState == "paired") | .hardwareProperties.udid' $devices_json | head -1)}
mkdir -p build
for item in "Documents/技术验证日志.txt" "Library/Application Support/PhotoAI/spike/launches.txt"; do
  xcrun devicectl device copy from --device $udid --domain-type appDataContainer --domain-identifier $bundle_id \
    --source "$item" --destination "build/${item:t}" >/dev/null && print "▸ build/${item:t}"
done

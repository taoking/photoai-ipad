# PhotoAI iPad 版

只给自己用的临时应急选片工具：出门没带 Mac 时，把索尼 A7C II 的卡插到 iPad Pro 11 英寸（2018，iPadOS 26）上看片、打星，把选中的原片导出到文件夹或“照片”App，然后清卡。是 Mac 版 PhotoAI 的精简移植，不上架，用免费 Apple ID 签名装机。

- [功能说明](功能说明.md)：怎么用。
- [重新打包](重新打包.md)：签名 7 天到期后怎么重装。
- 开发文档：[交接](docs/开发/交接.md)、[功能列表](docs/开发/功能列表.md)、[开发计划](docs/开发/开发计划.md)；记录：[沟通记录](docs/记录/沟通记录.md)、[验收](docs/记录/验收/)。

## 目录

```text
App/                    SwiftUI + UIKit 界面
Packages/PhotoAICore/   核心层 Swift 包（Mac 上 swift test）
UITests/                模拟器界面测试
Config/                 Info.plist、签名配置模板（Signing.xcconfig 只在本机）
Scripts/                reinstall.sh（构建并装到 iPad）、pull-log.sh、make-icon.sh
project.yml             XcodeGen 配置（.xcodeproj 由它生成，不进仓库）
docs/开发/              交接、功能列表、开发计划
docs/记录/              沟通记录、技术验证、验收记录
```

从不改动、移动、删除卡上的文件；清卡只删 iPad 本机的记录和预览。

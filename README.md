# 直播与课程知识骨架 · 预览测试版

本地 macOS 工具：记录用户选择的声音，转写为逐字稿，保存课件图片，整理成可回查图文来源的知识骨架，并保存自己的思考与重点。

> **这是未获 Developer ID 签名、未通过 Apple 公证的预览测试版。** 网络下载后的首次打开会遇到 macOS 安全拦截。请先阅读[安装限制与说明](docs/INSTALL.zh-CN.md)，自行判断是否信任来源；这不是已完成普通用户安装验收的正式版。

## 下载

**[下载 0.4.0-preview.1 安装包（DMG，约 406 MB）](https://github.com/mandycency-prog/knowledge-spine-releases/releases/download/v0.4.0-preview.1/KnowledgeSpine-0.4.0-preview.1-macOS-arm64.dmg)**

[版本与全部附件](https://github.com/mandycency-prog/knowledge-spine-releases/releases/tag/v0.4.0-preview.1) · [安装与首次使用](docs/INSTALL.zh-CN.md) · [资料与隐私说明](docs/PRIVACY.zh-CN.md) · [已做测试及未验证范围](docs/TESTING.zh-CN.md)

GitHub 自动生成的 “Source code (zip/tar.gz)” 是本仓库说明文件，不是软件；请下载上面的 `.dmg`。

| 条件 | 说明 |
|---|---|
| 电脑 | Apple 芯片 Mac（M 系列） |
| 系统 | macOS 14 或更高；未在 macOS 14 真机实测 |
| 不支持 | Intel Mac、Windows |
| 语音转写 | Python、FFmpeg、Whisper 基础模型随包提供，无需自行安装开发工具 |
| AI 整理 | 需配置自己的兼容 API 服务、密钥并确认文字发送授权，或选择自己提供的兼容 GGUF 本地模型 |
| 模型与费用 | 未包含整理用的大型模型或任何预置密钥；第三方 API 费用由使用者自行确认 |
| 更新 | 从本仓库 Releases 手动获取，当前应用没有内置自动升级功能 |

## 本次更新：课件图片

支持添加、拖入或粘贴课件截图，关联录音时间、节点和逐字稿；图片可参与导图和专题整理，并回查原图。可编辑导图包、Markdown 和 PDF 支持携带图片。详见[图片功能与配置](docs/IMAGES.zh-CN.md)。

**图片分析需要独立配置支持图文输入的 API，并明确同意发送图片及相关文字。** 文字服务或本地文字模型不能自动替代图片分析服务。不会自动下载视觉模型。

## 开始使用

1. 阅读安装限制，下载并打开 DMG，将“直播与课程知识骨架测试版.app”复制到 Applications 或自己的测试目录。
2. 全新安装使用空白资料库。测试版与正式版本使用独立资料和密钥存储；升级已有测试版会继续使用原测试版资料目录，更新前请先备份。
3. 在“模型与设置”中配置自己的 API 或本地整理模型；API 模式需明确同意发送任务所需文字。
4. 录音时，按照 macOS 提示授权你选择的屏幕/系统音频来源，再创建记录。也可使用应用支持的导图导入功能。
5. 检查生成内容与原话来源。识别、校订和 AI 概括都可能出错，不能将测试通过视为内容准确性保证。

## 校验安装包

文件：`KnowledgeSpine-0.4.0-preview.1-macOS-arm64.dmg`

SHA-256：`68c7004d56bcbb0e5048803ed1c2297558fb26aa3f06602d22fac7254f772ce8`

可下载同版本 `.sha256` 附件或查看 [SHA256SUMS.txt](SHA256SUMS.txt)。校验值用于核对文件是否与本次发布一致，不替代 Apple 签名、公证或使用者的信任判断。

## 反馈

欢迎在本仓库 Issues 中反馈系统版本、芯片型号、软件版本和可复现步骤。**Issues 对所有人公开，请勿上传 API 密钥、个人课程原稿、录音、真实导图或含私人信息的日志、截图。** 优先用不含个人内容的简短示例复现。

本仓库保存公开下载和通用说明。安装包内包含运行所需代码及第三方组件；依赖许可证、FFmpeg 对应源码归档位于应用内的 ThirdPartyNotices 目录，其他 Python 组件许可证保留在其安装目录中。详见[资料与隐私说明](docs/PRIVACY.zh-CN.md)。

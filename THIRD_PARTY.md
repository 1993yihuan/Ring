# 第三方资源

本仓库的代码采用根目录的 [LICENSE](LICENSE)（MIT）。下面的内容不属于该项目自己的代码，MIT 不覆盖它们。

## 网站字体

- `website/assets/fonts/inter.woff2`
- `website/assets/fonts/noto-sans-sc.woff2`

这两个是第三方字体文件。仓库里没有随附它们的许可文本或来源记录，压缩后的字体文件本身也无法核对来源，因此这里不代替许可声明。如果要再分发网站资源，请先向字体权利人确认许可。

文件名对应的上游项目是 Inter（The Inter Project Authors）与 Noto Sans SC（Google），它们各自的官方许可是 SIL Open Font License 1.1，以官方文本为准。

## 网站图片

- `website/assets/icons/*.png`、`website/assets/og.png`

这些是 Apple 系统应用图标和微信、OpenBot 图标的截图，用于说明产品效果。图标与商标的权利属于各自的持有人，不在本项目的 MIT 许可范围内。

## 应用本体

`Package.swift` 没有第三方代码依赖。`Ring.app` 只包含本项目自己的代码、由 `scripts/make-icon.sh` 生成的图标和系统框架，不包含上面列出的字体或第三方图标。

## 应用图标

`assets/icon/` 下是本项目的应用图标源图，由项目用图像生成工具生成并选定，生成记录见同目录的 `ring-icon-v1-design.md` 与 `ring-icon-v1-prompt.txt`。

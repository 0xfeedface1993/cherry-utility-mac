# 发布与官网

公开版本发布在 <https://odeployer.online/cherry-utility/>：Developer ID 签名、Apple 公证、通用二进制，内置 Sparkle 自动更新。下面的流程只有持有签名证书、公证凭据和 Sparkle 私钥的维护者能完整执行；凭据都在仓库之外，缺少时脚本直接失败。

## 一次发布

1. 改代码，更新 `project.yml` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`（build 号必须递增）。
2. 构建、签名、公证、生成 Sparkle 签名并写入 `Website/releases.json`：

   ```bash
   Scripts/release.sh <版本> <build> --note "改动 1" --note "改动 2"
   ```

3. 用 Sparkle 自带的 `sparkle-cli` 做更新端到端检查（不启动 App）：

   ```bash
   Scripts/verify-update.sh <上一版.dmg> .release/<版本>-<build>/CherryUtility-<版本>.dmg
   ```

4. 校验 Homebrew cask 与产物：

   ```bash
   Scripts/verify-cask.sh --release .release/<版本>-<build>/CherryUtility-<版本>.dmg .release/<版本>-<build>/cherry-<版本>.zip
   ```

5. 生成并部署官网、`appcast.xml`、`releases/latest.json`：

   ```bash
   Scripts/deploy-website.sh --artifacts .release/<版本>-<build>
   ```

6. 在 GitHub 上为这个版本打 tag `v<版本>` 并创建 Release（说明与官网更新日志一致），附上 `CherryUtility-<版本>.dmg`、`cherry-<版本>.zip` 及两个 `.sha256`。Homebrew cask 从这里下载，所以文件名和内容都不能改。
7. 发布 Homebrew cask 到 tap（先核对 Release 附件的 digest，再联网审核，最后推送）：

   ```bash
   Scripts/publish-homebrew.sh .release/<版本>-<build>
   ```

## 脚本

| 脚本 | 作用 |
|---|---|
| `Scripts/release.sh <版本> <build> [--note …]` | Release 归档（universal、Hardened Runtime、Developer ID）→ 重签 Sparkle 内嵌组件 → DMG（卷图标、背景图与图标布局）→ 公证并 staple → Sparkle EdDSA 签名 → 写入 `Website/releases.json`。另外打独立命令行的 `cherry-<版本>.zip`（单独公证），并按 `Packaging/homebrew/` 的模板渲染两个 cask。`--skip-notarize` 只试跑、不写 releases.json；`--resume` 沿用中断那次的 DMG 从公证继续；`CHERRY_DERIVED_DATA=.release/<上次>/DerivedData` 复用构建缓存 |
| `Scripts/make-dmg.sh <App> <输出.dmg>` | 用固定版本的 dmgbuild 制作 DMG，不打开 Finder。背景图由 `Design/icons/DMGBackground.svg` 经 `swift Scripts/render-dmg-background.swift` 生成 |
| `Scripts/verify-update.sh <旧.dmg> <新.dmg>` | 把旧版复制到临时目录，用只含新版的本地 appcast 让 `sparkle-cli` 完成检查、下载、EdDSA 校验与安装，再核对版本、签名和 Team；`--public <旧.dmg>` 只读询问公开 appcast。结束时还原 Sparkle 写入的偏好与缓存 |
| `Scripts/verify-cask.sh` | 渲染 `cherry-utility` / `cherry-cli` 两个 cask，在临时 tap 里跑 `brew style` / `brew audit`，核对二进制、签名、公证与 Gatekeeper；不安装任何东西 |
| `Scripts/publish-homebrew.sh [--dry-run] DIR` | 核对 GitHub Release `v<版本>` 已发布、两个附件的 digest 与本地 `.sha256` 一致、目录里的 cask 与模板渲染结果一致；在临时 tap 里联网跑 `brew style`、`brew audit --cask --strict --online` 与 `brew livecheck`，然后提交并推送到 [0xfeedface1993/homebrew-tap](https://github.com/0xfeedface1993/homebrew-tap)。本地克隆在 `.release/tools/homebrew-tap`；`--dry-run` 不提交 |
| `Scripts/deploy-website.sh [--artifacts DIR]` | 由 `Website/releases.json` 生成站点，复制到部署根 `releases/<id>/`，沿用上一版的下载文件，原子切换 `current` |
| `Scripts/rollback-website.sh` | 交换 `current` / `previous`，回到上一次部署 |

## 官网

- 源文件：`Website/src/`（纯静态 HTML / CSS，无构建依赖），`Website/build.py` 把版本、下载链接、更新日志填进模板，并生成 `appcast.xml` 与 `releases/latest.json`。
- `Website/releases.json` 是版本信息的唯一来源。只有 `notarized: true` 且带 Sparkle 签名的版本才会出现在下载按钮和 appcast 中；还没有可发布版本时，页面以「即将发布」模式渲染，下载按钮不可用。
- 本地预览：

  ```bash
  python3 Website/build.py --out /tmp/cherry-site && python3 -m http.server -d /tmp/cherry-site 8000
  ```

- 设计稿：`python3 Website/build.py --design <输出.html>` 生成 1440 px 与 390 px 两个宽度的自包含页面，用于导入 Figma。
- 线上路由：Cloudflare → 远端 FRPS → 本机 frpc（`locations = ["/cherry-utility"]`）→ Caddy `127.0.0.1:7904`（`Website/deploy/Caddyfile.template`）。

## Homebrew

`Packaging/homebrew/` 有两个相互独立的 cask 模板：`cherry-utility`（只装 App，`auto_updates true`）与 `cherry-cli`（只装命令行）。下载地址是 GitHub Release `v<版本>` 的附件，livecheck 读最新的 GitHub Release。`release.sh` 按版本和 SHA-256 渲染到 `.release/<版本>-<build>/`，`publish-homebrew.sh` 推到自建 tap [0xfeedface1993/homebrew-tap](https://github.com/0xfeedface1993/homebrew-tap)：

```bash
brew install --cask 0xfeedface1993/tap/cherry-utility
brew install --cask 0xfeedface1993/tap/cherry-cli
```

tap 的 CI 在每次推送时跑 `brew style`、联网 `brew audit`、`brew livecheck`，并在 macOS runner 上真的安装、卸载一遍。tap 里的 cask 不要手改，改模板后随下一个版本发布。

**为什么不进官方 homebrew-cask**：`brew audit --cask --new` 要求 GitHub 仓库建立满 30 天，作者自己提交时还要至少 90 fork、90 watcher 或 225 star（他人提交是 30 / 30 / 75），不满足时审核报 `GitHub repository not notable enough`。达到门槛后，把同样的两个 cask（去掉顶格说明）提交到 Homebrew/homebrew-cask，并在 tap 里用 `tap_migrations.json` 指向官方。

## 发布配置

- Bundle ID `online.odeployer.CherryUtility`，诊断日志的 subsystem 与偏好域也用它；命令行 `cherry` 的签名标识为 `online.odeployer.CherryUtility.cli`；预设文件 `.cherryprofile` 的 UTI 为 `online.odeployer.cherry-utility.profile`。
- Release 为通用二进制（arm64 + x86_64），Developer ID 签名，开启 Hardened Runtime，经 notarytool 公证并 staple。App 不在沙盒里（IOKit HID 需要），所以 Sparkle 不需要 installer launcher service；`release.sh` 在签 App 之前用 Developer ID 加安全时间戳重签 Sparkle 的内嵌组件和 `cherry`。
- Sparkle 使用 EdDSA 签名，公钥写在 Info.plist 的 `SUPublicEDKey`，更新源为 `https://odeployer.online/cherry-utility/appcast.xml`。签名证书、公证凭据（App Store Connect API key）与 Sparkle 私钥都放在仓库之外，由 `release.sh` 从本机的配置文件读取。
- `CFBundleDevelopmentRegion` 为 zh-Hans，只有 zh-Hans 一种本地化：多加 en 会让英文系统上的 Sparkle 对话框和日期格式变成英文（见 [自动化 · App Intents](automation.md#app-intents)）。
- build 号必须单调递增，Sparkle 按它比较版本。

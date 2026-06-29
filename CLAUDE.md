# CLAUDE.md — Folium (staraple fork)

给未来在本仓库工作的 Claude Code:这是一个**我们 fork 的第三方项目**。下面是项目概览、与上游同步的方法,以及一堆**已经踩过的坑**——照着做能让「同步上游 / 编译打包」顺畅很多,别重新趟一遍。

---

## 1. 项目是什么

**Folium** 是一个 iOS 多系统模拟器 App(上游 `folium-app/Folium`,作者 jarrodnorwell)。本仓库是它的 fork:`staraple/Folium`。

- **UI/App 层**:Swift 6 + UIKit(`Folium/` 目录,target `Folium`,产物 `Folium.app`)
- **模拟器核心**:C++,各自编成静态库 target,被主 App 链接:
  | Target | 系统 | 目录 |
  |---|---|---|
  | `Mandarine` | PlayStation 1 | `Mandarine/`(DuckStation 系:cdrom/gpu/spu/mdec…) |
  | `Tomato` | Game Boy Advance | `Tomato/` |
  | `Grape` | 任天堂 DS/DSi | (上游近期新增) |
- **系统枚举**:`Folium/Enumerations/System.swift`(core ↔ 主机映射的权威来源)
- **工具链**:Xcode 26 / iOS 部署目标 26.0 / Swift 6 / C++23 with cxx-interop
- **默认 bundle id**:`com.antique.Folium-iOS`(上游作者的;签名分发时需换成自己的)

### 依赖布局(重要)
1. **`SharedDependencies/`**(仓库内 SPM 包):vendored 的 C++ 依赖(cereal/glib/httplib/cryptopp/libchdr/…),**不需要 brew 装 boost/vulkan**。
2. **`../AntiqueKit`**(仓库**外**、同级目录的 SPM 包):工程用相对路径 `../AntiqueKit` 引用,提供 `ColourKit/FontKit/SettingsKit/ConstraintKit/ExtensionsKit/OnboardingKit` 等 UI 模块。
   - **不是 git submodule**(本仓库无 `.gitmodules`),`git clone --recursive` 拉不到它。
   - 缺它则 `xcodebuild` 在 "Resolve Package Graph" 直接失败。修复:
     ```bash
     git clone https://github.com/jarrodnorwell/AntiqueKit.git ../AntiqueKit
     # 它跟上游同步即可,只在你要改它源码时才需要 fork
     ```
3. **PLzmaSDK**:`SharedDependencies` 的唯一远程 SPM 依赖(`github.com/jarrodnorwell/PLzmaSDK`),由 SwiftPM 自动解析。

---

## 2. 编译出 .ipa

一条命令(未签名,真机,侧载用):
```bash
./build-ipa.sh
```
产物:`build/Folium.ipa`(arm64 / platform IOS / 未签名)。用 **AltStore / SideStore** 侧载——侧载会用开发证书重签,自动带上 `get-task-allow`,JIT 才可用。

`build-ipa.sh` 已封装下面所有坑的处理,正常情况不用手动干预。它做的事:校验 Xcode → 确保 `../AntiqueKit` 在 → 检查 iOS 模拟器运行时 → 把 PLzmaSDK 重定向到本地镜像(规避代理)→ `xcodebuild -target Folium`(未签名)→ 打 `Payload/` 成 ipa。环境变量:`FOLIUM_SKIP_MIRROR=1` / `FOLIUM_FORCE=1` / `FOLIUM_BUNDLE_ID=...`。

---

## 3. 同步上游更新

远端约定:`origin` = 我们的 fork(`staraple/Folium`,可推);`upstream` = 原仓库(`folium-app/Folium`,只拉,push 已禁用)。

```bash
git fetch upstream
git rebase upstream/main          # 我们的补丁少且是纯新增,rebase 历史最干净
git push --force-with-lease origin main   # rebase 改写了历史,用安全强推
```
- 备选:`git merge upstream/main` + 普通 `git push`(多一个 merge commit,但不用强推)。**两者择一,别混用。**
- 我们自有的改动目前只有 `build-ipa.sh` + `.gitignore` 追加 + 本文件,跟上游代码不重叠,冲突概率极低。
- 同步上游后,**`../AntiqueKit` 也顺手更一下**(`git -C ../AntiqueKit pull`),以防上游 Folium 用了它的新 API。
- 同步完若要重新出包,直接再跑 `./build-ipa.sh`。

---

## 4. 已知的坑(踩过,别重犯)

1. **必须完整 Xcode,不是 Command Line Tools**:`xcode-select -p` 若指向 CommandLineTools,`xcodebuild` 用不了。修:`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`,首次还要 `sudo xcodebuild -license accept` 和 `sudo xcodebuild -runFirstLaunch`。

2. **代理黑洞导致 SwiftPM 解析卡死**:某些代理(fake-ip / TUN 模式)对 GitHub「连得上、传不动」,xcodebuild 内部的 libgit2 在 "Resolve Package Graph" 阶段会**无限卡住**(连到 `198.18.x.x` 这类 fake-ip,0 字节)。git 命令行走代理是通的。解法已固化进 `build-ipa.sh`:用 git CLI 建本地裸镜像 + `git config --global url.<mirror>.insteadOf <github-url>` 把远程依赖重定向到本地,解析秒过,脚本退出时自动清理该配置。手动排查时:`lsof -nP -p <pid> | grep 198.18` 能确认是不是这个问题。

3. **Xcode 26 的 actool 需要 iOS 模拟器运行时**:`Folium/App Icon.icon` 是 Icon Composer(液态玻璃)格式,actool 编译时要用模拟器运行时**渲染图标**,否则报 `No available simulator runtimes ... supportedRuntimes=[]`,卡在 `CompileAssetCatalogVariant`。
   - 装运行时:`xcodebuild -downloadPlatform iOS`(约 8.5GB)。
   - **装完不会立刻生效**:磁盘镜像 Ready 了,但要等它注册进 **`xcrun simctl list runtimes`**(经典接口,actool 用的)才行——常需重启 Mac,或让 Xcode GUI 的 Components 反复重试到注册成功。
   - **判定真正可用**:`xcrun simctl list runtimes` 非空(`== Runtimes ==` 下有 iOS 条目)。注意**不是** `simctl runtime list`(那是磁盘镜像视图,Ready 了 actool 也可能还看不到)。可单独冒烟测试 actool(见 `scratch/actool-smoketest.sh`,已被 .gitignore 忽略)。

4. **构建用 `-target` 而非 `-scheme`**:平台组件没完全注册时,`-scheme` 会因 destination 不合格报 "iOS 26.5 is not installed";`-target Folium -sdk iphoneos` 绕过 destination 检查。注意 `-target` **不能**和 `-derivedDataPath` 同用(冲突),用 `SYMROOT=...` 指定输出。

5. **不要用 Archive 打包**:Archive/分发会剥掉 `get-task-allow`,而模拟器 JIT 靠它。本工程没有 checked-in 的 entitlements;`get-task-allow` 在开发签名时注入。所以流程是「`build` 而非 `archive`」+「手动 `Payload/` zip」+「侧载时由 AltStore 重签注入 get-task-allow」。

6. **脚本是 macOS 自带 bash 3.2**:`set -u` 下展开空数组要用 `${arr[@]+"${arr[@]}"}`,直接 `"${arr[@]}"` 会报 `unbound variable`。

---

## 5. 约定

- 提交身份:个人 GitHub 账号,且用 **GitHub 隐私邮箱(`@users.noreply.github.com`)** 提交(本仓库已把 local `git config user.email` 配成 noreply)。这是**公开仓库**,提交别暴露真实邮箱 / 工作邮箱。
- `build/`、`scratch/`、`*.log`、`xcuserdata/` 已被 `.gitignore` 忽略,别提交进库。
- 改动尽量保持「纯新增、与上游隔离」,这样上游同步永远轻松。

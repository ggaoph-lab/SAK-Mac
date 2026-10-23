# SwitchSwitcher

一个 macOS 原生的 Nintendo Switch 游戏文件转换工具，用 SwiftUI 编写。灵感来自 Windows 上的 [Switch Army Knife (SAK)](https://github.com/dezem/SAK)。

## 功能

- **万物转 NSP**：导入 XCI / NSZ / XCZ / NSP；单文件直接转 NSP，多文件（本体 + 更新 + DLC）合并成一个 NSP
- **XCI ⇄ NSP 互转**：也可以直接输入 NSZ / XCZ
- **NSZ / XCZ 压缩与解压**：可调压缩等级，压缩后可校验
- **合并本体 + 更新 + DLC**：合并成一个 XCI 或 NSP；同一内容有多个版本时，自动保留最新版本
- **检测更新**：转换 / 合并 / 万物转 NSP 开始前会自动对照 titledb 检查；若缺少或落后会弹窗确认是否继续，更新包名称可复制。也可在侧边栏手动检测。不下载任何游戏内容

所有功能都支持把文件拖进窗口，处理时实时显示进度和日志。

## 系统要求

- macOS 14 或更高版本
- Python 3.9 或更高版本（Homebrew 或 python.org 安装的都可以）
- 你自己从 Switch 上导出的 `prod.keys`

## 构建

需要安装 Xcode（SwiftUI 的宏插件只随 Xcode 提供，单独的命令行开发工具不够）。

```bash
./scripts/build_app.sh
```

脚本会自动下载 NSC_BUILDER 和 nsz 的源码到 `vendor/`，打上 `patches/` 里的 macOS 兼容补丁，编译后在 `dist/` 下生成 `SwitchSwitcher.app`。

## 使用

1. 打开 App，到「设置」里点「安装后端」。首次安装需要联网，大约 1 分钟，后端会装到 `~/Library/Application Support/SAKMac`。
2. 在「设置」里选择你的 `prod.keys`，默认读取 `~/.switch/prod.keys`。
3. 选择功能，拖入文件，点击开始。输出默认在 `~/Downloads/SAK Output`。

这个 App 只做了本机签名（ad-hoc）。拷到别的 Mac 上第一次打开时，需要右键选择「打开」。

## 致谢与借鉴的开源项目

本项目只是一个图形界面，真正处理文件的是下面这些开源项目，感谢它们的作者。

| 项目 | 作者 | 许可证 | 在本项目中的用途 |
| --- | --- | --- | --- |
| [Switch Army Knife (SAK)](https://github.com/dezem/SAK) | kempa (dezem) | 未声明 | 功能设计和界面思路的参考。没有使用它的任何代码或二进制文件 |
| [NSC_BUILDER](https://github.com/julesontheroad/NSC_BUILDER) | julesontheroad | MIT | XCI/NSP 互转、合并本体/更新/DLC 的后端（`squirrel.py`） |
| [nsz](https://github.com/nicoboss/nsz) | Nico Bosshard、Blake Warner | MIT | NSZ/XCZ 压缩与解压的后端 |
| [NUT](https://github.com/blawar/nut) | Blake Warner (blawar) | GPL-3.0 | NSC_BUILDER 和 nsz 中都有代码源自 NUT |

后端在运行时用到的 Python 库：pycryptodome、zstandard、enlighten、tqdm、colorama、urllib3、Unidecode、requests、Beautiful Soup、chardet、pykakasi、Pillow、ujson、googletrans。

### 对 NSC_BUILDER 的修改

`patches/nscb-macos.patch` 对 NSC_BUILDER 做了两处修改，让它能在 macOS 和新版 Python 上运行：

- 生成 `cnmt.xml` 时用的 Windows 路径分隔符 `\` 改成了跨平台写法
- Python 3.11 起，`str(IntEnum)` 返回数字而不是 `Content.META` 这种名称，导致合并时识别不到任何内容。补丁恢复了原来的字符串格式

## 免责声明

本项目不包含、也不会下载任何 Nintendo 密钥、固件或游戏文件。「检测更新」仅从公开 titledb 拉取标题/版本元数据，用于对照你本地已有的文件。请只处理你自己合法拥有的游戏。本项目与 Nintendo 无关。

## 许可证

本项目代码以 [MIT](LICENSE) 许可证发布。打包进 App 的第三方组件遵循各自的许可证。

# atvv

把 T1-Remote（VID `0x620A` / PID `0x0407`）的语音键映射成 macOS 快捷键（默认 `Ctrl+I`），用于唤起微信输入法的语音输入。

## 菜单栏 App（主程序）

```bash
./build.sh                 # 生成 build/AtvvMenu.app
open build/AtvvMenu.app
```

点击菜单栏图标展开面板：

- ATVV 连接状态、当前是否在语音中
- 「启用遥控器」开关：打开才连接并接收按键事件
- 当前语音模式（长按触发 / 短按切换）
- 右下角齿轮进入设置

设置里可以切换语音模式、录制触发快捷键、导出日志（日志同时写入 `~/Library/Logs/AtvvMenu/atvv.log`）。

首次运行需要授予**辅助功能**权限（系统设置 → 隐私与安全性 → 辅助功能），否则注入的按键会被系统丢弃。

## 命令行工具（调试用）

```bash
swiftc -O cli/main.swift -o atvv
./atvv              # 默认：ATVV 事件驱动热键
./atvv --hid        # 纯 HID 对照模式
./atvv --audio      # 抓遥控器音频，落 WAV 到当前目录
./atvv --selftest   # 自检：启动后发一次 1.5 秒的 Ctrl+I
```

命令行版本用文件锁 `atvv.lock` 保证单实例，`Ctrl+C` / `kill` 会走统一清理。

## 工作方式

默认模式常连 ATVV 服务 `ab5e0001`，**只订阅 CTL**：

- `04`（AUDIO_START）→ 按下，立刻发 `0D 00` 关掉设备自起的音频会话，同时按住 `Ctrl+I`
- `00 02`（HTT release）→ 松手，释放 `Ctrl+I`
- `00 08`（15 秒传输超时）→ 兜底释放
- `00 00`（我方关麦的应答）→ 忽略
- 60 秒硬性兜底，防止松手信号丢失

不订阅 AUDIO 是刻意的：一旦订阅，设备就停发 HID，按键只能靠 ATVV 事件。

注入时 flags 必须是 `0x40001`（`maskControl | NX_DEVICELCTLKEYMASK | maskNonCoalesced`），缺设备位微信输入法会直接忽略。

## 设备行为备忘

- 短按只发 AC Search（`02 21 02`），不发 `0xAA`；长按才发语音键
- 未订阅 ATVV 时 HID 正常，但空闲超过 15 秒后第一下会被固件吞掉
- 订阅 ATVV 后 HID 完全静默，此时 `04`/`00 02` 才是可靠信号

详细协议和排障过程见 `NOTE.md` 和 `~/code/doc/design/airmouse/t1-atvv-voice.md`。

# atvv

把 T1-Remote（VID `0x620A` / PID `0x0407`）的语音键映射成 macOS 的 `Ctrl+I`，用于唤起微信输入法的语音输入。

## 用法

```bash
swiftc -O main.swift -o atvv
./atvv              # 默认：ATVV 事件驱动热键
./atvv --hid        # 纯 HID 对照模式
./atvv --audio      # 抓遥控器音频，落 WAV 到当前目录
./atvv --selftest   # 自检：启动后发一次 1.5 秒的 Ctrl+I
```

需要「输入监控」和「辅助功能」权限。程序用文件锁 `atvv.lock` 保证单实例，`Ctrl+C` / `kill` 会走统一清理，不会留后台监听。

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

详细协议和排障过程见 `~/code/doc/design/airmouse/t1-atvv-voice.md`。

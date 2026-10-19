# Translating the Hardware Diagnostic Toolkit's screens

Brief for the translators (Haiku agents) that fill `toolkit/i18n/<lang>.json`.
Kept in the repository: the scratch copy of 1.21 was lost to a temp-dir
cleanup in 1.24.

The toolkit is a bootable USB stick that a laptop repair bench (Data
Dynamics, Johor, Malaysia - mostly Dynabook / Toshiba laptops) uses to test
machines: drives, RAM, CPU, GPU, fan, battery, keyboard, screen, Wi-Fi, USB
ports, disk imaging. The readers are repair technicians at arm's length from
the screen. The English is terse, plain and practical; keep the translation
the same: short, direct, the words a technician in that country uses. Never
longer than needed - screens are tight.

## Input and output

A todo file: one line per string, `id<TAB>English`. Answer in a file with
exactly one line per input line, same order, `id<TAB>translation`, UTF-8,
LF line endings, no header. An EMPTY translation (`id<TAB>`) means "show the
English as it is" - use it for anything that is not screen text (code
identifiers, regexes, struct formats, file names, CSV headers, log-only
lines) and for words that must stay English.

## Rules

1. `{0}`, `{1}`, ... stand for values filled in at run time (numbers, names,
   other phrases). Keep every one of them, exactly once, unchanged; move them
   where the grammar needs them. Never add one. Never translate inside them.
2. Keep as written: product and brand names (Dynabook, Toshiba, Intel,
   Windows, Linux, Ubuntu, Ventoy, Rufus, MemTest86+, Macrium, Clonezilla,
   SetDmiAll), acronyms and standards (Wi-Fi, USB, USB-C, PCIe, NVMe, SATA,
   SSD, HDD, BIOS, UEFI, CPU, GPU, RAM, MAC, SMART, DMI, ACPI, HDMI, SD, MBR,
   GPT, NTFS, exFAT, FAT32, AER, 802.11ax ...), units (MB, GB, TB, MHz, GHz,
   Mbps, Gbps, GT/s, W, V, A, mWh, %, ms, rpm, C for degrees), file names,
   commands, device names (/dev/...).
3. Key names stay English: Enter, Esc, Q, Y, N, S, M, Space, Shift,
   Left/Right, arrows inside "Left/Right". "- / +" stays.
4. Keep separators the English uses between parts of a line (" - ", ": ",
   "  " double spaces in hints): the screen splits on them.
5. A fragment stays a fragment (", slot {0}", "(version {0})"): keep its
   leading comma or brackets.
6. Chinese and Japanese: full-width punctuation inside sentences is fine;
   keep a space between Latin words / numbers and CJK only where natural.
7. No quotes, notes or explanations in the answer file.

## Glossary - use these exactly

| English | zh_CN 简体 | zh_TW 繁體 | ja 日本語 | ko 한국어 |
|---|---|---|---|---|
| PASS | 通过 | 通過 | 合格 | 통과 |
| FAIL | 失败 | 失敗 | 不合格 | 실패 |
| WARN | 警告 | 警告 | 警告 | 경고 |
| MARGINAL | 临界 | 臨界 | 要注意 | 경계 |
| NOT TESTED | 未测试 | 未測試 | 未テスト | 미테스트 |
| OK (a result) | 正常 | 正常 | 正常 | 정상 |
| Full run | 完整测试 | 完整測試 | フルテスト | 전체 테스트 |
| test (noun) | 测试 | 測試 | テスト | 테스트 |
| Driver check | 驱动检查 | 驅動程式檢查 | ドライバーチェック | 드라이버 점검 |
| driver | 驱动程序 | 驅動程式 | ドライバー | 드라이버 |
| firmware | 固件 | 韌體 | ファームウェア | 펌웨어 |
| Error log | 错误日志 | 錯誤日誌 | エラーログ | 오류 로그 |
| Settings | 设置 | 設定 | 設定 | 설정 |
| System information | 系统信息 | 系統資訊 | システム情報 | 시스템 정보 |
| More info | 更多信息 | 更多資訊 | 詳細情報 | 추가 정보 |
| Peripherals | 外设 | 周邊裝置 | 周辺機器 | 주변 장치 |
| Command prompt | 命令提示符 | 命令提示字元 | コマンドプロンプト | 명령 프롬프트 |
| Results | 结果 | 結果 | 結果 | 결과 |
| report | 报告 | 報告 | レポート | 보고서 |
| Disk imaging | 磁盘镜像 | 磁碟映像 | ディスクイメージ | 디스크 이미징 |
| image (backup) | 镜像 | 映像檔 | イメージ | 이미지 |
| partition | 分区 | 磁碟分割 | パーティション | 파티션 |
| unallocated | 未分配 | 未配置 | 未割り当て | 할당되지 않음 |
| How this test works | 测试原理 | 測試原理 | テストのしくみ | 테스트 원리 |
| Battery | 电池 | 電池 | バッテリー | 배터리 |
| Charger / charging | 充电器 / 充电 | 充電器 / 充電 | 充電器 / 充電 | 충전기 / 충전 |
| Fan | 风扇 | 風扇 | ファン | 팬 |
| GPU | GPU | GPU | GPU | GPU |
| Keyboard | 键盘 | 鍵盤 | キーボード | 키보드 |
| Touchpad | 触控板 | 觸控板 | タッチパッド | 터치패드 |
| Touchscreen | 触摸屏 | 觸控螢幕 | タッチスクリーン | 터치스크린 |
| Screen | 屏幕 | 螢幕 | 画面 | 화면 |
| Camera | 摄像头 | 相機 | カメラ | 카메라 |
| Sound / speakers | 声音 / 扬声器 | 聲音 / 喇叭 | サウンド / スピーカー | 사운드 / 스피커 |
| Lid | 屏幕盖 | 螢幕上蓋 | 天板 (ふた) | 덮개 |
| Ethernet / LAN / cable | 以太网 / LAN / 网线 | 乙太網路 / LAN / 網路線 | イーサネット / LAN / LAN ケーブル | 이더넷 / LAN / 랜선 |
| Wireless | 无线 | 無線 | 無線 | 무선 |
| network | 网络 | 網路 | ネットワーク | 네트워크 |
| drive (HDD/SSD) | 硬盘 | 硬碟 | ドライブ | 드라이브 |
| the stick / USB stick | U盘 | USB 隨身碟 | USB メモリ | USB 메모리 |
| port / socket | 接口 | 連接埠 | ポート | 포트 |
| card reader | 读卡器 | 讀卡機 | カードリーダー | 카드 리더 |
| motherboard | 主板 | 主機板 | マザーボード | 메인보드 |
| Theme | 主题 | 主題 | テーマ | 테마 |
| Language | 语言 | 語言 | 言語 | 언어 |
| Text size | 文字大小 | 文字大小 | 文字サイズ | 글자 크기 |
| Enter to go back | 按 Enter 返回 | 按 Enter 返回 | Enter で戻る | Enter: 뒤로 |
| Q = stop / Q to stop | Q 停止 | Q 停止 | Q で停止 | Q: 중지 |
| arrows | 方向键 | 方向鍵 | 矢印キー | 방향키 |
| Yes / No | 是 / 否 | 是 / 否 | はい / いいえ | 예 / 아니요 |
| power menu | 电源菜单 | 電源選單 | 電源メニュー | 전원 메뉴 |

Chinese (Traditional) is for Taiwan / Hong Kong readers: use Taiwan
vocabulary (螢幕, 網路, 硬碟, 記憶體 for RAM in prose, 連接埠), never a
character-by-character conversion of the Simplified text. Japanese: plain,
polite-neutral UI style (です/ます only in full-sentence instructions; labels
as nouns). Korean: concise UI style (labels as nouns, instructions in -세요 or
noun-ending forms).

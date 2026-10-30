# 八段锦 iOS 开发工程 0.1.1-dev

目标手机：用户提供 iPhone 16 / iOS 26.0.1。2026-10-30 首版0.1.0已通过Sideloadly个人签名安装，Windows观察到Done/100%；用户完成信任和开发者模式，确认进入五标签主界面、扫描可见WT。尚未从设备回读具体型号/系统版本。

**这是诊断版，不是已完成全功能验收的iOS交付版。** 0.1.0已通过8项XCTest及两个平台编译；用户反馈单台连接短暂变1再回0。源码核对发现首版错误使用标准短UUID：CoreBluetooth扩展后的尾部是9B34FB，而安卓生产版使用维特自定义9A34FB。0.1.1改为三个完整UUID，新增与安卓夹具对照和CoreBluetooth短UUID不等价的回归测试，并保留失败原因和最近200条连接事件。0.1.1是否通过构建以对应Actions为准，真机修复效果仍须重新连接验证。

## 独立性与依据

- 新目录 `android_imu_lab/baduanjin_ios`；不修改、安装或覆盖现有安卓工程、官方App、开发签名及实验数据。
- Bundle ID `dev.imulink.baduanjin.ios`；界面名称“八段锦采集”。SwiftUI + CoreBluetooth + Foundation/CryptoKit，最低iOS17，无第三方运行库。
- 依据现有 `baduanjin_wit` 的生产协议、质量、固定编号/默认正常/补录、存储及导出规则移植；Java源码及协议向量来源哈希在测试夹具内保留。不是维特完整官方iOS源码，也不声称原厂iOS连接容量已移植。
- iOS识别传感器使用CoreBluetooth UUID，不假装它是MAC；须重新扫描并逐部位绑定。文件的`address`列在iOS存UUID，并在metadata中写`identity_kind=corebluetooth_uuid_not_mac`。不要跨平台按该列直接合并设备身份。

## 当前源码范围

下表区分已有源码、核心自动测试和仍待真机验证的部分。首版主界面和扫描由用户真机确认；尚未完成成功订阅、原始数据录制及真机导出。云编译不替代真机验证。

|功能|首批源码状态|尚需验证/完善|
|---|---|---|
|BLE扫描、最多15个选定目标、UUID持久绑定、单只更换、连接/重连|扫描已由用户确认；0.1.1修正维特完整UUID；串行状态队列、两个并行建连、背压和轮转调度；失败原因与连接日志可查看/导出|修复后订阅、单台与多台容量/频率验证|
|WT9011DCL拆包、signed16、A/G/M/Q换算|185组627帧Java生产解析器对照测试已在Mac通过|新iPhone原始回包核验|
|实时数值、加速度短时趋势、15部位状态列表|已有|人体图精细布局、全部四项趋势、无障碍与真机布局|
|匿名受试者、8×15固定编号、动作名编辑/历史、补录/尝试审计|核心与浏览/编辑界面已有；120编号、补录新尝试、质量否决的核心测试通过；旧尝试不覆盖|正式采集全链路连接、120条真人采集；自动测试记录不计为实际实验|
|三秒准备期、原始记录、手动结束|仅开放5–120秒的有限诊断接口，界面为60秒诊断；诊断自动到时，不占正式编号|正式手动结束、超过60秒仅提示尚未开放；不能把诊断到时行为用于正式采集|
|质量与告警|整段接收率、首尾/中间最大间隙、完整秒欠帧、500ms/2s停更、原始异常记录|与新平台历史实测交叉重算；所有15台每项30Hz仍须验收|
|写盘、异常退出恢复|串行有界队列、低空间保护、错误否决；写盘与缺少摘要恢复测试通过，原始字节保留|iPhone写盘、低空间、异常退出实测|
|ZIP导出|单次/当前任务分类、保留全部尝试、CRC32+SHA-256、文件清单、进度和取消、系统分享；Mac Swift实际导出后Python独立核验通过|真机“文件”App/电脑取回实测；大文件与中途取消的真机验证|
|佩戴参考姿态、引导动作、人工确认、派生姿态|数据结构及入口保留；尚未完整移植，界面明确未开放|完成移植和真实佩戴验收；`relative_pose.csv`当前只有表头，不冒称已经计算相对姿态|
|统一配置|只读核对RATE/AXIS6/ORIENT/输出内容已有|批量写入/回读流程尚未接入；当前不发送配置写指令|
|加速度校准|静态窗口检查可输出具体失败条件；校准入口保留并禁用|尚未移植完整三指令协调器和审计；真实执行前必须重新确认原始+Z放稳、告知时长|

**正式录制按钮当前禁用**，因为佩戴、配置写入/校准及iOS验收未完成，不放宽安卓正式门限。声音/振动关闭；录后回放不增加；息屏优化暂缓。当前离开前台会结束正在进行的诊断并记异常；不是后台持续采集承诺。用户已取消两小时连续测试，本项目不安排该测试。

## 文件和导出

仅在本App Documents/Baduanjin 下操作：`roster.json`、`studies/`、`active-study.json`、`sessions/`、`exports/`。启用iOS文件共享；没有访问照片、联系人、麦克风、其他App目录或iCloud容器。

每条诊断产生 `notifications.jsonl`、`samples.csv`、`relative_pose.csv`、`metadata.json`、`events.jsonl`、`summary.json`。相对姿态未实现前仅保留CSV表头并如实注明。任务复核另存`action-review.json`，不改原始摘要。未结束记录重启后标为`incomplete_process_exit`。ZIP32单包超过4GiB明确报错；不生成溢出的损坏ZIP。取消或失败导出只留下本App内`.partial.zip`，不会作为成功文件分享，原始记录不删除。

`canSendWriteWithoutResponse`只表示本地可提交；日志明确`peripheral_acknowledged=false`，不伪造Android式写回调，也不将本地提交当传感器执行应答。查询上限90次/秒/台与实际接收率不同；手机接收时间不证明四项或多台内部同步。

## Windows已执行的检查

```powershell
& 'D:\anacond\python.exe' -X utf8 tools/make_fixtures.py
& 'D:\anacond\python.exe' -X utf8 tools/generate_project.py
& 'D:\anacond\python.exe' -X utf8 tools/validate_source.py
```

在本工程目录运行。第一项需要旁边现有安卓工程和JDK，读取历史通知但夹具只保留字节、解析结果和源文件哈希，不包含MAC、时间戳、匿名受试者或原始实验包。后两项不需要安卓数据。结构检查只查括号/字符串、plist、Xcode引用及明确的只读边界，**不替代Swift编译**。

## Mac / 云构建入口

可在有Xcode26及相应SDK的Mac运行：

```bash
bash tools/build_macos.sh
```

脚本依次生成工程、结构检查、`swift test`、Python校验Swift实际生成的ZIP、iOS模拟器编译、iPhone ARM64编译，全部通过才生成`build/output/baduanjin-ios-<版本>-unsigned.ipa`。编译失败立即停止并保留日志，不打空IPA。Swift测试覆盖维特完整GATT UUID、生产解析对照、整段缺口、120编号/补录/质量否决、历史恢复、具体静止门限、文件写入/ZIP/取消。

`.github/workflows/ios-build.yml` 在main源码更新或手动启动时执行GitHub macos-15构建，固定选择Xcode 26.0.1，最长25分钟，不需要Apple账号、密码、证书或签名私钥，不调用IMU。上传到仓库时以本目录作为仓库根目录。仅文档更新不自动触发构建；构建是否通过以对应提交的Actions结果为准。保留XCTest XML、两个平台编译日志及导出校验结果，云产物保留7天。

若用本地Xcode，打开 `Baduanjin.xcodeproj`，选择Baduanjin Scheme。核心是同目录本地Swift Package；不需要下载第三方依赖。安装时选择自己的Personal Team并按Xcode提示配置设备。先只测诊断功能，再推进功能表中未完成项。

## 无Mac、普通Apple账号的安装路径

1. 用户已明确授权将本iOS源码上传到公开仓库 [mollyn525/molwlwwla](https://github.com/mollyn525/molwlwwla)，用云Mac进行上述无签名构建。上传范围仅限本工程源码、去标识协议测试向量及构建脚本，不含原始实验数据或账号/证书。
2. 首版已经在Windows通过第三方Sideloadly个人签名安装；更新继续使用同一账号和Bundle ID，不卸载原App。也可在可用Mac上由Xcode Personal Team安装。
3. Apple登录、密码、验证码、设备信任和开发者模式由用户本人完成，不发到聊天、不放到仓库/Actions。免费个人签名有7天有效期及数量限制，长期实验要安排重签和数据备份。
4. 保留同一Apple账号和稳定Bundle ID更新，避免卸载造成App数据丢失。安装前先核对签名后Bundle ID确实是本独立App。

首次真机检查：扫码/订阅单台→原始通知及整段频率→导出回电脑比对→三台/七台/十五台逐步验证。iOS当前没有安卓ADB式现成自动控制链；编译与算法测试可自动，权限/信任/签名由用户完成，真机界面和BLE操作在工具接通前需用户配合。没有把模拟器编译当作真实蓝牙测试。

## 2026-10-30 云构建结果

- 已验证源码提交：`757464c1839289ca397e380dd165aabd8954d57b`；[对应Actions运行](https://github.com/mollyn525/molwlwwla/actions/runs/41028838701)全部通过。后续仅README更新不改变该产物对应源码。
- Xcode 26.0.1 / iOS 26.0 SDK；8项XCTest，0失败、0错误；185组627帧生产协议对照通过。Swift Testing另外显示的0项不等于XCTest没有运行，实际数量见`swift-tests.xml`。
- Swift实际写出的诊断ZIP包含11个文件，Python独立验证CRC32、SHA-256、文件清单和诊断不占正式编号。这个测试不等于已从真实iPhone导出。
- 模拟器和iPhone ARM64编译成功；Swift源码编译告警为0。剩余AppIntents元数据跳过通知符合本App未使用AppIntents的情况。
- 未签名IPA：`baduanjin-ios-0.1.0-unsigned.ipa`，SHA-256 `480d450d4a4f2a083778f9a045dcf06176082cab0d024b8c7f77178a381a1d39`。
- 此处为0.1.0构建证据；后续个人签名安装、主界面和扫描已验证，单台连接失败待0.1.1修复后复测。正式录制、佩戴、配置写入、校准、十五台连接及每项30Hz均没有iOS验收结论。

## 官方依据

- [Apple：Personal Team与7天配置文件](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Apple：Xcode26及iOS26 SDK](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)
- [Apple：CoreBluetooth设备UUID](https://developer.apple.com/documentation/corebluetooth/cbpeer/identifier)
- [Apple：开发者模式](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [Apple：信任此电脑](https://support.apple.com/en-gb/109054)
- [Sideloadly官方FAQ：个人签名和支持范围](https://sideloadly.io/faq)
- [GitHub：手动运行云构建](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)

远端仓库使用已连接的GitHub工具访问；不依赖本机CLI缓存登录。工程不包含Apple账号或签名材料。云构建产物是未签名IPA，不能直接安装；构建通过不代表iPhone蓝牙、连接容量或采集质量已通过验收。

# 八段锦 iOS 开发工程 0.1.0-dev

目标手机：用户提供 iPhone 16 / iOS 26.0.1。2026-10-30 在 Windows 已观察到 Apple iPhone USB 设备、驱动状态 Started，以及正在运行的 Apple Mobile Device Service；尚未从设备回读具体型号/系统版本，也没有安装本项目App。

**这是首批移植源码，不是已完成全功能验收的iOS交付版。没有Swift/Xcode编译结果、IPA或iPhone实测结果。** Windows可完成的文件/工程结构检查和Java对照数据生成已完成；必须运行下面的Mac构建后才能知道Swift编译及测试是否通过。

## 独立性与依据

- 新目录 `android_imu_lab/baduanjin_ios`；不修改、安装或覆盖现有安卓工程、官方App、开发签名及实验数据。
- Bundle ID `dev.imulink.baduanjin.ios`；界面名称“八段锦采集”。SwiftUI + CoreBluetooth + Foundation/CryptoKit，最低iOS17，无第三方运行库。
- 依据现有 `baduanjin_wit` 的生产协议、质量、固定编号/默认正常/补录、存储及导出规则移植；Java源码及协议向量来源哈希在测试夹具内保留。不是维特完整官方iOS源码，也不声称原厂iOS连接容量已移植。
- iOS识别传感器使用CoreBluetooth UUID，不假装它是MAC；须重新扫描并逐部位绑定。文件的`address`列在iOS存UUID，并在metadata中写`identity_kind=corebluetooth_uuid_not_mac`。不要跨平台按该列直接合并设备身份。

## 当前源码范围

下表的“已有”仅指源码和测试用例已经编写；不表示已编译或真机通过。

|功能|首批源码状态|尚需验证/完善|
|---|---|---|
|BLE扫描、最多15个选定目标、UUID持久绑定、单只更换、连接/重连|已有CoreBluetooth实现；串行状态队列、两个并行建连、无响应写入按系统背压和轮转调度|真实iPhone首次安装、订阅、单台与多台容量/频率验证|
|WT9011DCL拆包、signed16、A/G/M/Q换算|已有；185组627帧Java生产解析器对照数据|Mac执行Swift对照测试；新iPhone原始回包核验|
|实时数值、加速度短时趋势、15部位状态列表|已有|人体图精细布局、全部四项趋势、无障碍与真机布局|
|匿名受试者、8×15固定编号、动作名编辑/历史、补录/尝试审计|核心与浏览/编辑界面已有；默认正常必须同时满足质量和正常结束；旧尝试不覆盖|正式采集全链路连接、120编号实测；绝不以模拟记录冒充真人采集|
|三秒准备期、原始记录、手动结束|仅开放5–120秒的有限诊断接口，界面为60秒诊断；诊断自动到时，不占正式编号|正式手动结束、超过60秒仅提示尚未开放；不能把诊断到时行为用于正式采集|
|质量与告警|整段接收率、首尾/中间最大间隙、完整秒欠帧、500ms/2s停更、原始异常记录|与新平台历史实测交叉重算；所有15台每项30Hz仍须验收|
|写盘、异常退出恢复|串行有界队列、低空间保护、错误否决、只补异常摘要而不补原始数据|云测试及iPhone异常退出实测|
|ZIP导出|单次/当前任务分类、保留全部尝试、CRC32+SHA-256、文件清单、进度和取消、系统分享|Mac运行Swift导出后由Python独立核验；真机“文件”App/电脑取回实测|
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

脚本依次生成工程、结构检查、`swift test`、Python校验Swift实际生成的ZIP、iOS模拟器编译、iPhone ARM64编译，全部通过才生成`build/output/baduanjin-ios-0.1.0-unsigned.ipa`。编译失败立即停止并保留日志，不打空IPA。Swift测试覆盖生产解析对照、整段缺口、120编号/补录/质量否决、历史恢复、具体静止门限、文件写入/ZIP/取消。

`.github/workflows/ios-build.yml` 在main源码更新或手动启动时执行GitHub macos-15构建，最长25分钟，不需要Apple账号、密码、证书或签名私钥，不调用IMU。上传到仓库时以本目录作为仓库根目录。仅文档更新不自动触发构建；构建是否通过以对应提交的Actions结果为准。

若用本地Xcode，打开 `Baduanjin.xcodeproj`，选择Baduanjin Scheme。核心是同目录本地Swift Package；不需要下载第三方依赖。安装时选择自己的Personal Team并按Xcode提示配置设备。先只测诊断功能，再推进功能表中未完成项。

## 无Mac、普通Apple账号的安装路径

1. 用户已明确授权将本iOS源码上传到公开仓库 [mollyn525/molwlwwla](https://github.com/mollyn525/molwlwwla)，用云Mac进行上述无签名构建。上传范围仅限本工程源码、去标识协议测试向量及构建脚本，不含原始实验数据或账号/证书。
2. 编译通过后可在Windows用第三方Sideloadly进行个人签名安装；或在可用Mac上由Xcode Personal Team安装。第三方工具官方说明支持普通Apple账号和iOS26，但本机和此iPhone尚未验证，不能保证一次成功。
3. Apple登录、密码、验证码、设备信任和开发者模式由用户本人完成，不发到聊天、不放到仓库/Actions。免费个人签名有7天有效期及数量限制，长期实验要安排重签和数据备份。
4. 保留同一Apple账号和稳定Bundle ID更新，避免卸载造成App数据丢失。安装前先核对签名后Bundle ID确实是本独立App。

首次真机检查：扫码/订阅单台→原始通知及整段频率→导出回电脑比对→三台/七台/十五台逐步验证。iOS当前没有安卓ADB式现成自动控制链；编译与算法测试可自动，权限/信任/签名由用户完成，真机界面和BLE操作在工具接通前需用户配合。没有把模拟器编译当作真实蓝牙测试。

## 官方依据

- [Apple：Personal Team与7天配置文件](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Apple：Xcode26及iOS26 SDK](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes)
- [Apple：CoreBluetooth设备UUID](https://developer.apple.com/documentation/corebluetooth/cbpeer/identifier)
- [Apple：开发者模式](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [Apple：信任此电脑](https://support.apple.com/en-gb/109054)
- [Sideloadly官方FAQ：个人签名和支持范围](https://sideloadly.io/faq)
- [GitHub：手动运行云构建](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)

远端仓库使用已连接的GitHub工具访问；不依赖本机CLI缓存登录。工程不包含Apple账号或签名材料。云构建产物是未签名IPA，不能直接安装；构建通过不代表iPhone蓝牙、连接容量或采集质量已通过验收。

# gauss-amm 相对原生 openGauss 5.0.2 的源码对比与实测报告

日期：2026-07-29

结论对象：`gauss-amm` commit `74632f4b89cc6e019b3c07bb860c42622e638025`

对比基线：openGauss 官方 `v5.0.2`，commit `48a25b114825483bc8f2b8b88ee7366e4dc9f875`

## 1. 结论摘要

该分支不是只增加若干参数的“外层调度器”，而是在 buffer pool、Executor、Sort/Hash、PageWriter、事务回调和统计视图中接入了一套真实的粒度化自适应内存管理（AMM）实现。它能够把原属 shared buffer 的物理页按 granule 安全下线，再作为分析查询的专属 extent 使用；查询结束后可清理、回收并交还 buffer pool。allocator-only、决策树 admission、空闲 AP 回收和 TP 热保护路径均已在 ARM64 openEuler VM 中得到正向实测。

但当前版本只能评价为“功能完整度较高的工程原型”，不具备生产启用条件，主要原因是：

1. **P0：`feedback-only` 存在可复现的数据库级 SIGSEGV。** 普通 SELECT 会因错误的 plan walker context 破坏栈内存并使线程式 `gaussdb` 整体退出。
2. **P1：普通决策树 admission 没有执行文档声明的 4 MB 最小 grant。** 实测只授予 0.783 MB，却独占 64 MB granule，并产生约 1.136 GB spill。
3. **P1：模型读取宿主 `/proc/meminfo`，不识别 cgroup。** 本 VM 上模型看到约 64 GiB，而实际限额为 32 GiB。
4. 配置文档、`gs_guc` 白名单、状态语义和默认测试调度存在多处漂移，运维可控性与回归保障不足。

因此，现阶段不建议在生产环境打开 `gs_amm_native_auto_mode` 或 `gs_amm_feedback_only_mode`。修复 P0 后，allocator-only 可以作为第一条隔离验证路径；决策树和反馈闭环应在修正 grant 下限、cgroup 特征和观测语义后再做并发及长稳测试。

## 2. 比较范围与可信边界

| 项目 | 本次采用值 |
|---|---|
| 私有源码 | `sources/gauss-amm-master/` |
| 私有归档 SHA-256 | `ff01c9e1ce8a3fa49310e17efef1c629e46eae9b3ce2e90cc2f22dd279ddc7e5` |
| 原生基线 | 官方 openGauss `v5.0.2` |
| 上游 commit | `48a25b114825483bc8f2b8b88ee7366e4dc9f875` |
| 上游归档 SHA-256 | `956758728b100897746ae7e7e7f7dfcdc82e22e5c086c8b76cfa60243dc657ae` |
| 文件级差异 | 98 个文件 |
| 表面 diff | 1,221,946 行新增、662 行删除 |

表面新增行数不能当成功能规模：约 102 万行来自误打包的 `preproc.output`，另有生成代码、备份文件和 3 个 x86-64 可执行文件。机器可读清单见 [`upstream-v5.0.2-name-status.diff`](../evidence/upstream-v5.0.2-name-status.diff) 和 [`upstream-v5.0.2.stat`](../evidence/upstream-v5.0.2.stat)。

核心 AMM 实现集中在：

- `src/gausskernel/storage/buffer/gs_amm.cpp`：共享状态、granule 生命周期、借还、控制器、admission、统计。
- `src/gausskernel/storage/buffer/gs_amm_query.cpp`：执行计划特征、决策树、原生 Executor 生命周期和 feedback。
- `src/gausskernel/storage/buffer/gs_amm_io.cpp`：设备 I/O 采样。
- `src/common/backend/utils/mmgr/ammgranule.cpp`：查询侧 granule allocator。
- `src/include/storage/gs_amm.h` 与 `src/include/storage/gs_amm_types.h`：状态机、token、共享结构和接口。
- `src/common/backend/utils/mmgr/workmem_dtree.cpp`：静态决策树模型。

## 3. 原生 5.0.2 与该分支的功能差异

原生 5.0.2 虽声明了 `memorypool_enable`、`memorypool_size` 和 `MemoryPool` 类接口，但全树未找到 `MemoryPool::Init/CreatePool/Malloc` 等实现或消费点。这是未接通的遗留接口；通信、MOT 和动态负载管理中的其他 pool 是独立子系统，不能视为本 AMM 的原生前身。

| 能力 | 原生 openGauss 5.0.2 | gauss-amm 分支 |
|---|---|---|
| 通用 memory pool GUC | 有声明，未接通实现 | 保留，同时新增完整 `gs_amm_*` 参数族 |
| buffer pool 动态缩减 | 无 | 按 granule 从尾部下线 buffer 页 |
| buffer/AP 物理内存复用 | 无 | 同一 `BufferBlocks` 映射在 buffer 与 AP extent 间转换 |
| 状态机与并发保护 | 无 | state、owner、epoch/generation、lease、grant token |
| 查询自动识别 | 无 | ExecutorStart 识别 Sort/Hash/Agg/Window 等计划 |
| work_mem 预测 | 无 | 19 维静态决策树，三档 cache/one-pass/multi-pass bound |
| 查询专属 allocator | 无 | Sort/Hash 走 backend-local granule extent arena，无 heap fallback |
| TP/I/O 保护 | 无 | TPS drop、dirty/writeback、diskstats、spill/hash multipass guard |
| 自适应反馈 | 无 | 记录 peak/spill/runtime，并设计校准或 feedback-only 调整 |
| SQL 可观测性 | 无 | `gs_amm_status()`、granule 状态、控制/测试函数和计数器 |

### 3.1 物理内存借还

共享内存随 buffer pool 初始化，granule 默认把连续 buffer block 切为 64 MB 单位。代码实际包含六个状态：

`BUFFER_ACTIVE → BUFFER_DRAINING → RECLAIMING → FREE → AP_RESERVED → AP_ACTIVE`

AP 释放后经 `RECLAIMING/FREE` 返回 buffer 侧。仓库文档所写“五状态”遗漏了一个状态，应以 `src/include/storage/gs_amm.h:18` 的枚举为准。

借出路径不是简单改计数：

1. 先发布 `BUFFER_DRAINING`，使 freelist 和 buffer hash 新访问跳过该范围。
2. 在 buffer header/content/mapping 锁约束下检查 dirty、pin、I/O 和 hash 引用。
3. clean、unpinned、无 I/O 的页才允许失效；遇到未满足条件的页会记录 pending，交给 pagewriter 优先刷写，或回滚为 active。
4. 完成后通过 `madvise(DONTNEED)`（失败则清零）释放物理页，再进入 `FREE`。
5. AP admission 使用 token/generation 预留、激活 granule，查询侧 allocator 只能在自身 grant 范围内分配。

对应 buffer table、freelist 和 Executor 的接入点分别位于 `src/gausskernel/storage/buffer/buf_table.cpp:90`、`src/gausskernel/storage/buffer/freelist.cpp:301` 和 `src/gausskernel/runtime/executor/execMain.cpp:240`。

### 3.2 查询 admission 与 allocator

实现提供三类自动路径：

- **allocator-only**：固定目标 grant，用于验证 extent allocator，不依赖模型。
- **dtree**：从执行计划和系统特征生成三档 work_mem bound，按当前 free capacity 选择最高可满足档位。
- **feedback-only**：以 bootstrap grant 启动，再依据运行期 peak/spill/runtime 调整 grant 和 AP 并发 slot。

每个 backend 保存自己的 grant token、generation 和 executor frame；每个 granule 记录 owner/generation，因此并发正确性并非依赖共享的单一 current 字段。Sort/Hash 的申请走 `AmmGranuleContext`，超过本 grant 后进入 spill，不悄悄退回普通 heap，allocator-only 实测确认这一链路已真正执行。

### 3.3 控制器和保护信号

PageWriter 周期性采集 commit、物理读、dirty/writeback、临时文件、Hash multipass 以及 `/proc/diskstats`。控制器可以：

- 从 buffer 借 granule 给 AP；
- 在 TP 恢复或 AP 空闲时回收 granule；
- 通过 resize cooldown、rate limit、deadband 和 guard 避免频繁抖动；
- 在 TPS 显著下跌或 I/O 热时阻断 shared buffer 收缩，并记录 guard/rollback。

TP 热保护已实测：TPS 从 100 降为 10 后，EWMA 基线为 95.5、recent 为 55、drop ratio 为 0.424084；请求把 shared buffer 从 1024 MB 缩到 960 MB 被以 `guard_blocked reason=hot` 拒绝，所有一致性检查通过。

## 4. 决策树与反馈实现评价

决策树是编译期生成的 19 维静态模型，共 129 类输出叶，原始输出约 0.0196–304.46 MB，multi-pass 最低被钳制到 0.0625 MB。`leaf_id` 是三档输出值的 FNV 哈希，不是树路径 ID；相同输出的不同叶会共享校准状态。

当前存在四个关键偏差：

1. `gs_amm_select_bound_grant_kb()` 只在 allocator-only/feedback-only 分支应用 `allocator_only_min_kb`；普通 dtree 分支未应用 `gs_amm_ap_min_grant_mb`。
2. 首次 admission 在 free granule 为 0 时只同步执行一次 controller step，默认受 64 MB batch/rate limit 约束。首次大查询可能先降档或 fallback，需等待后台轮次积累容量。
3. 系统内存特征来自 `/proc/meminfo`，没有读取 cgroup v2 `memory.max/current`，容器和 OrbStack machine 中会高估容量。
4. 模型中若干系统内存分裂阈值集中在约 205–217 GB，与本次 32 GB 场景不匹配，提示训练环境/特征分布需要重新校准。

反馈遥测也有语义问题：获得 native grant 的事务会从 TP 样本排除，但 admission 失败后 fallback 的分析事务仍计入 TP；混合事务则整体排除。TP P95 当前固定写入 `0.0`，文档中的 P95 保护没有真实采集源。

## 5. 已确认缺陷与优先级

### P0：feedback-only 可使 gaussdb 整体崩溃

`src/gausskernel/storage/buffer/gs_amm_query.cpp:107` 的 `gs_amm_feedback_operator_walker(Node *, bool *)` 把一个 `bool` 地址直接作为 `plan_tree_walker()` context。通用 walker 实际要求 context 以 `MethodPlanWalkerContext` 开头；同文件正常的 feature walker 使用了带该 base 的 `GsAmmWorkMemFeatureContext`。

根节点本身是目标算子时会提前返回，因而第一条 Aggregate 查询成功；下一条普通状态 SELECT 需要递归，walker 把相邻栈内存当作 list/context，最终在 `list_concat()` SIGSEGV。FFIC 栈为：

`list_concat → walk_plan_node_fields → plan_tree_walker → GsAmmExecutorStart → ExecutorStart`

崩溃地址为 `0xcca0500000000004`。证据见 [`feedback-only-sigsegv-ffic.log`](../evidence/feedback-only-sigsegv-ffic.log) 和 [`gs_amm_native_feedback_only.actual`](../evidence/gs_amm_native_feedback_only.actual)。

修复要求：为 feedback walker 定义包含 `MethodPlanWalkerContext base` 的 context，按通用 walker 约定初始化；增加“根节点不匹配但子节点匹配”和“计划树完全不匹配”两类回归测试。

### P1

- 普通 dtree grant 未执行 4 MB 最小值，造成 0.783 MB 逻辑 grant 占用 64 MB 物理粒度。
- cgroup 不感知，32 GiB machine 被模型当作约 64 GiB 系统。
- `cluster_guc.conf` 仅覆盖部分 AMM GUC；`gs_guc` 实测拒绝 `gs_amm_shared_buffers_min_mb` 和 `gs_amm_dynamic_target_mb`，只能通过 `ALTER SYSTEM` 或启动 `-c` 绕过。
- TP P95 固定为 0，相关保护名存实亡。
- 当前状态下 production 打开 native/feedback 会暴露新查询生命周期和 buffer pool 变更面，不应在修复前启用。

### P2

- `native_last_event_granted_kb` 与 `memory_mode` 在 release 时被清零，无法保留“最后事件”；共享 last-event 槽也会被并发查询互相覆盖。
- 文档只强调 `gs_amm_native_auto_mode`，但实际还必须先打开总开关 `gs_amm_enabled`。
- 文档称五状态、把 resize/granule 参数生效级别写混，需按 GUC 注册代码修订。
- 两个新增 regress SQL 未加入默认 schedule；CMake unit tests 也不会被现有 Make 构建包装器自动执行。
- 源码归档含巨型预处理输出、备份文件和 x86 二进制，污染 diff 且可能导致增量构建误装错误架构制品。
- `contrib` 中重复存放一份 workmem 决策树模型，容易发生实现漂移。

## 6. 编译、安装与运行状态

### 6.1 环境

| 项目 | 值 |
|---|---|
| OrbStack machine | `gauss-amm-lab` |
| 与既有机器关系 | 独立 machine/rootfs；未使用 `pgracbench` |
| OS | openEuler 24.03 LTS-SP4 ARM64 |
| 资源上限 | 8 vCPU、32 GiB cgroup memory、128 GiB disk cap |
| 安装目录 | `/home/sqlrush/gauss-amm-src/mppdb_temp_install` |
| 数据目录 | `/home/sqlrush/gauss-amm-data` |
| 监听 | `127.0.0.1:15432` |

官方 5.0.2 的平台检测只精确识别 openEuler 22.03。24.03 缺少旧的 `sys/sysctl.h`/`sys/vtimes.h`，本次使用源码已有的 `OPENEULER_MAJOR/WITH_OPENEULER_OS` 条件分支完成构建，没有修改 AMM 业务源码。

OrbStack 不提供 `/sys/devices/system/node`，MOT 初始化无法建立 NUMA CPU 映射。MOT-enabled ARM64 制品已保留；最终运行验收制品仅为适配该 VM 关闭 MOT，AMM 代码没有因此裁剪。

源码归档中夹带的 `gs_loader` 是 x86-64，且 Makefile 目标没有 prerequisites，首次未被重建。本次已用官方 ARM binarylibs GCC 7.3 强制重建；最终安装树可执行文件扫描无 x86 制品，`ldd` 无缺失库。

### 6.2 最终制品

`gaussdb -V`：`openGauss 5.0.2`，编译时间 `2026-07-29 16:53:26`

| 文件 | SHA-256 |
|---|---|
| `gaussdb` | `3c5cd9f54adf616647d171029483330b79f0d6764b4e3c63682866a5522a73f9` |
| `gsql` | `a28ac67cdef4a688ab94b4a8ca125d64aebfb24e591344dfaed8bbdaf26f7593` |
| `gs_loader` | `798acff1e99460a20ce1d392634f22b43b20d735da4657cc61f2f3440824dd0c` |

构建日志见 [`build-mot-enabled.log`](../evidence/build-mot-enabled.log) 和 [`build-no-mot.log`](../evidence/build-no-mot.log)。

### 6.3 当前安全状态

实例已从 feedback-only 崩溃中恢复并正常运行。最终复核结果为：

- 基本 SQL `SELECT 1` 成功；
- `gs_amm_enabled=on`；
- `gs_amm_native_auto_mode=off`；
- `gs_amm_feedback_only_mode=off`；
- `active_ap_count=0`；
- cgroup `oom=0`、`oom_kill=0`。

即保留 AMM 手工验证能力，但默认关闭风险最高的自动查询路径。

## 7. 实测矩阵

| 测试 | 关键结果 | 结论 |
|---|---|---|
| 50,000 行 × 1 KB 两轮外排 | count/distinct 均 50,000；grant 和 granule 全清理 | 通过 |
| 空闲 AP 回收 | 128 MB 容量、68 MB grant；TP recovery 回收 64 MB，保留 4 MB；重复回收安全 | 通过 |
| native allocator-only | 100,000 行排序正确；eligible/admit/release 各 1；313,701 次 allocator 成功；复用约 286 MB | 通过 |
| native dtree | 查询正确、生命周期完整；实际 grant 0.783 MB，spill 1,136,495,808 bytes | 功能通过，暴露 P1 |
| feedback-only | 首条 5,000 行查询返回；下一条普通 SELECT 导致连接丢失和 gaussdb SIGSEGV | 失败，P0 |
| TP 热保护 | 42.4% TPS drop 下，1024→960 MB shrink 被阻断；guard/rollback/一致性全为真 | 通过 |
| 崩溃后恢复 | 无 cgroup OOM；强制关闭 native/feedback 后启动并通过基本 SQL | 通过 |

原始输出位于 [`evidence/`](../evidence/)；服务器日志尾部见 [`server-log-tail.log`](../evidence/server-log-tail.log)。

## 8. 建议的修复与复测顺序

1. 修复 feedback walker context，并把不匹配根节点、嵌套匹配、完全不匹配计划纳入默认回归。
2. 在所有 dtree admission 档位统一执行最小 grant；或把物理粒度降到可接受水平，并明确“逻辑 grant/物理占用”两套指标。
3. 系统内存特征改为 `min(MemAvailable, cgroup memory.max-current)`，处理 `max`、父 cgroup 和 v1 兼容。
4. 补齐 `cluster_guc.conf`，统一总开关、native 开关、SIGHUP/POSTMASTER 生效级别和状态字段文档。
5. 接入真实延迟分位数；重新定义 TP 样本对 fallback 和混合事务的归类。
6. 清理归档污染，把新增 regress/unit/isolation 测试接入默认 CI。
7. 依次执行单会话 allocator-only、并发 allocator-only、dtree、feedback、故障注入和 24–72 小时长稳；每阶段都检查 dirty/pinned invalidation、epoch/token、grant 泄漏、OOM 和 TPS 回归。

在完成前四项之前，本分支适合隔离研发验证，不适合生产流量。

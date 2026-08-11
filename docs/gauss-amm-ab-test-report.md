# AMM 内存池动态调整 —— 开启/关闭对照测试报告

> 被测对象：`gauss-amm` @ `74632f4b89cc6e019b3c07bb860c42622e638025`（基线 openGauss v5.0.2）
> 依据：PPT《内存池动态调整方案验证》阶段 ①–⑤
> 实验：2026-08-11 17:24:13 – 17:50:35，同一实例连续跑两组，唯一变量 `gs_amm_native_auto_mode`
> 性质：第三方测试评估，**未修改被测代码**
> 数据：`evidence/ab-20260811-172413/` · 脚本：`scripts/`

---

## 一、结论速览

同一条 SQL、同样 449387 行、同一个执行计划，只切一个 GUC：

| | **AMM 介入** | **AMM 不介入** |
|---|---|---|
| Sort Method | `external merge` | `quicksort` |
| 内存 / 磁盘 | **Disk: 238368 kB**（落盘 233 MB） | **Memory: 475082 kB**（全内存 464 MB） |
| 达成率（实得/申请 512 MB） | — | **90.6%** |
| Total runtime | **914.885 ms** | **669.450 ms** |

**AMM 开启使一条本可全内存完成的排序落盘 233 MB，耗时增加 36.7%。** 这与 PPT 阶段① "调大慢 SQL 内存、降低落盘" 的主张方向相反。

TP 侧同样是负向的（阶段 ①–④ 共 9 分钟）：

| | TP operations | 相对 |
|---|---|---|
| AMM 介入 | 251,789 | — |
| AMM 不介入 | **356,524** | **+41.6%** |

四项验收行为无一达成，详见 §四。根因是 AMM 的 work_mem 决策树对该类排序**低估约 460–640 倍**，详见 §五。

---

## 二、测试环境

| 项 | 值 |
|---|---|
| 载体 | OrbStack machine `gauss-amm-lab`，openEuler 24.03 LTS-SP4 ARM64 |
| CPU / 内存 | 18 核 / cgroup 32 GiB |
| 数据库 | openGauss 5.0.2 + AMM，`127.0.0.1:15432` |
| `shared_buffers` | 2048 MB = **32 granule**（`granule_size_mb=64`） |
| 共享池地板 | `gs_amm_shared_buffers_min_mb` = 512 MB（8 granule） |
| **可迁移带宽** | **1536 MB = 24 granule** |
| 控制器 | `controller_horizon=3`、`beam_width=4`、`deadband_mb=32` |
| 迁移节奏 | `resize_batch_mb=64`、`resize_rate_limit_mb=64`、`resize_cooldown_ms=2000` |
| 保护阈 | `tp_pressure_guard=80`、`io_pressure_guard=80`、`tp_jitter_limit=0.30` |
| 队列 | `ap_queue_limit=16`、`ap_queue_timeout_ms=5000` |
| 授信 | `ap_min_grant_mb=4`、回退值 `fallback_work_mem_kb` ≈ 64 MB |
| 数据 | TP 表 `accounts` 1464 万行；AP 表 `gsbench.sort_data` 402.7 万行 |

### 变量选择说明

两组唯一差异是 `gs_amm_native_auto_mode`。选它而非 `gs_amm_enabled=off` 的理由是源码里这道门闩：

```c
// src/gausskernel/storage/buffer/gs_amm_query.cpp:862
if (!gs_amm_native_auto_mode || !top_level_executor)
    return false;          // ← 关掉后，预测/准入/改写 work_mem 全部不执行
```

它正是决定 **AMM 是否介入执行器内存分配**的开关。关掉它等于恢复原生 openGauss 的 work_mem 行为，同时保留 AMM 的池遥测，使两组可用同一采样器、同一组指标直接对比。

**旁证**：关闭组结束时的准入计数器与开启组结束时**完全相同**（`native_eligible_count=726`、`native_admit_count=284`、`native_reject_count=442`、`effective_downgrade_count=477`）——计数器冻结，证明关闭组中 AMM 一次准入动作都没做。

---

## 三、测试工具与负载实现

两个负载均来自 **gsbench v1.1.6**（`sqlrush/gsbench`）。

### 3.1 TP 负载 —— 场景 101 `tp_cpu`

点查为主的 OLTP 负载，作用是产生持续的 TPS 基线，使 AMM 的 `tp_baseline_tps` / `tp_recent_tps` / `drop_ratio` 有意义。

已打自制的 TP 键采样补丁：启动时对 `accounts` 全表 1464 万行做键采样（`stride=1`），保证点查随机命中全表而非热点区。

```
INFO tp_key_sample accounts_rows=14641933 sampled_keys=14641933 stride=1
INFO scenario=tp_cpu workers=2 duration=9m0s rate=unlimited
```

**工作集 2.9 GB > 缓冲池 2 GB 是刻意设计**：只有工作集大于缓冲池，`buffer_hit` 才会真实下降，PPT 阶段⑤ 的判据才可测。代价是 TP 大量命中磁盘、TPS 噪声偏大。

### 3.2 AP 负载 —— 场景 201 `memory_workmem_sort`

这是本报告的核心工具。它分**校准**与**压测**两阶段，源码在 `internal/gsbench/scenario_workmem.go`。

#### 阶段一：校准（`calibrateWorkMemRange`）

目的是找到"能让排序算子真正吃掉目标 work_mem、且不落盘"的行数区间。

会话设置（`buildWorkMemSessionSetup`，:461）：

```sql
SET LOCAL work_mem='524288kB'      -- 目标值
SET LOCAL query_dop=1              -- 关并行，保证算子内存可归因
SET LOCAL explain_perf_mode=normal -- 使 EXPLAIN 输出可解析
```

探测语句（`workMemCalibrationSQL`，:381）：

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT max(rn), sum(payload_len) FROM (
  SELECT row_number() OVER (ORDER BY payload, sort_key DESC, id) AS rn,
         CAST(length(payload) AS bigint) AS payload_len
  FROM gsbench.sort_data
  WHERE dist_key BETWEEN 1 AND <range>
) AS gsbench_sorted
```

搜索逻辑是**倍增探测 + 二分收敛**，最多 16 次，目标带 70%–97%：

```go
// calibrateWorkMemRange()
if observation.Spilled || observation.UsedKB > upperKB {
    high = candidate - 1        // 落盘或超上界 → 区间压小
    bracketed = true
} else {
    low = candidate + 1         // 未落盘但用量不足 → 区间抬高
}
if bracketed {
    candidate = low + (high-low)/2      // 二分
} else {
    candidate *= 2                       // 倍增
}
```

命中 `70% ≤ UsedKB ≤ 97%` 且未落盘 → `target_met=true`；16 次未命中 → 取"最大的不落盘观测"兜底，`target_met=false`。

> **关键**：`EXPLAIN ANALYZE` 是真执行的（`explain.cpp:993`：`if (es->analyze) eflags = 0;`，`EXEC_FLAG_EXPLAIN_ONLY` 仅用于裸 `EXPLAIN`），因此**校准阶段同样会被 AMM 拦截**。这一点在 §五 有决定性影响。

#### 阶段二：压测（`workMemWorkerOperations`，:490）

每个 worker 执行：

```sql
BEGIN;
SET LOCAL work_mem='524288kB';
SET LOCAL query_dop=1;

DECLARE gsbench_cursor_<id> NO SCROLL CURSOR FOR
  SELECT id, sort_key, payload
    FROM gsbench.sort_data
   WHERE dist_key BETWEEN 1 AND <校准区间>
   ORDER BY payload, sort_key DESC, id;

FETCH 1 FROM gsbench_cursor_<id>;
```

随后 Go 侧阻塞直到 duration 结束，收尾才 `CLOSE ALL; ROLLBACK`。

#### 201 为什么能"占住" work_mem —— 本测试成立的前提

**排序是阻塞算子：要吐出第 1 行，必须先把全部数据排完。** 所以 `FETCH 1` 会强制 tuplesort 读入 `<range>` 行、按 work_mem 额度建立完整排序状态。

拿到第一行后**不再 FETCH、不提交事务**，游标保持打开 → tuplesort 的内存不释放 → 整个 duration 期间这块内存被真实占用。

```
SET LOCAL work_mem='512MB'   声明需求
        ↓
DECLARE CURSOR ... ORDER BY   定义必须排序的查询
        ↓
FETCH 1                       触发全量排序，真正分配内存   ← 内存在此落地
        ↓
阻塞持有                       持续占用，形成稳定压力
        ↓
CLOSE ALL; ROLLBACK           释放
```

**在原生 openGauss 下这套机制是有效的**，本次实测直接验证：

```
native_auto_mode = off
 Sort  (actual time=588.974..646.528 rows=449387 loops=1)
   Sort Method: quicksort  Memory: 475082kB          ← 全内存持有 464 MB
 Total runtime: 669.450 ms
```

475082 kB / 524288 kB = **90.6%**，落在 gsbench 的 70%–97% 目标带内，`target_met=true`。

即：**201 确实能把 work_mem 占住，前提是数据库真的把 work_mem 给它。**

### 3.3 五阶段编排

`scripts/run-ab.sh`，两组各跑一遍，每阶段 2 分钟，对应 PPT step ①–⑤：

| 阶段 | PPT 设计意图 | TP worker | AP 份数 | AP work_mem | AP 总请求 |
|---|---|---|---|---|---|
| ① 内存富裕 | 基线 | 2 | 2 | 128 MB | 256 MB |
| ② 触及上限 | **借内存** | 2 | 2 | 512 MB | 1024 MB |
| ③ 保护基准 | **TP 托底保护** | 2 | 4 | 512 MB | 2048 MB |
| ④ 反压排队 | **队列保护** | 2 | 8 | 512 MB | 4096 MB |
| ⑤ 基准突增 | **TP 增流是否扩共享缓存** | **8** | 8 | 512 MB | 4096 MB |

AP 采用 `scripts/ap-holder.sh`（gsql 复刻 201 的语句序列），因为 gsbench 的 stale recovery 读取数据库侧共享 journal，同一时刻只能运行一个进程，无法用它做精确的分阶段并发爬坡。复刻语句与 `workMemCursorSQL` **逐字一致**，仅持有方式由阻塞改为 `pg_sleep`。

区间常量取自 AMM 关闭时的实测校准值：128 MB 档 `28086`，512 MB 档 `112347`。

---

## 四、AMM 开启 vs 关闭 —— 逐阶段对比

> 列义：`SB低/高` = 该阶段 `active_mb` 极值；`动已用` = `dynamic_used_mb` 峰值；`AP` = `active_ap_count` 峰值；`入队/超时/反压` = 累计计数器阶段内增量（精确值）；`热` = `tp_guard_hot=true` 采样数；`借/还` = 按 `pool_event_id` 去重的事件数。

| 阶段 | 模式 | 样本 | SB低 | SB高 | 动已用 | AP | 队长 | 入队 | 超时 | 反压 | drop峰 | 热 | 借 | 还 | hit低% |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| tp_warmup | **ON** | 41 | 1920 | 1920 | 1 | 1 | 0 | 0 | 0 | 0 | 0.0000 | 0 | 1 | 0 | 0.4 |
| tp_warmup | OFF | 43 | 1792 | 1792 | 0 | 0 | 0 | 0 | 0 | 0 | 0.0000 | 0 | 0 | 1 | 30.1 |
| ① stage1 | **ON** | 113 | 1856 | 1920 | 2 | 2 | 0 | 0 | 0 | 91 | 0.6196 | 31 | 6 | 66 | 54.2 |
| ① stage1 | OFF | 113 | 1792 | 1792 | 0 | 0 | 0 | 0 | 0 | **0** | **0.0672** | **0** | 0 | 0 | 65.2 |
| ② stage2 | **ON** | 111 | 1856 | 1920 | 12 | 2 | 0 | 0 | 0 | 110 | 0.4193 | 43 | 5 | 75 | 59.4 |
| ② stage2 | OFF | 114 | 1792 | 1792 | 0 | 0 | 0 | 0 | 0 | **0** | **0.0288** | **0** | 0 | 0 | 65.8 |
| ③ stage3 | **ON** | 22 | 1792 | 1792 | 24 | 4 | 1 | 1 | 34 | 35 | 0.2207 | 0 | 1 | 20 | 84.8 |
| ③ stage3 | OFF | 114 | 1792 | 1792 | 0 | 0 | 0 | 0 | 0 | **0** | 0.1012 | 0 | 0 | 0 | 83.7 |
| ④ stage4 | **ON** | 51 | 1792 | 1792 | 24 | 4 | 5 | 1 | 38 | 34 | 0.1870 | 0 | 6 | 15 | 84.5 |
| ④ stage4 | OFF | 134 | 1792 | 1792 | 0 | 0 | 0 | 0 | 0 | **0** | 0.1247 | 0 | 0 | 0 | 84.0 |
| ⑤ stage5 | **ON** | 61 | 1792 | 1792 | 24 | 4 | 5 | 0 | 34 | 91 | 0.7628 | 33 | 8 | 38 | 24.4 |
| ⑤ stage5 | OFF | 142 | 1792 | 1792 | 0 | 0 | 0 | 0 | 0 | **0** | 0.8898 | 19 | 0 | 20 | 28.0 |
| cooldown | **ON** | 56 | 1792 | 1792 | 0 | 0 | 0 | 0 | 0 | 71 | 0.9736 | 52 | 0 | 52 | 100.0 |
| cooldown | OFF | 56 | 1792 | 1792 | 0 | 0 | 0 | 0 | 0 | 0 | 0.9719 | 44 | 0 | 44 | 99.0 |

全程汇总：

| | 借出深度 | 距地板 | 动已用峰 | AP峰 | 借 / 还 | 反压 | 入队 |
|---|---|---|---|---|---|---|---|
| **AMM 介入** | 1984 → 1792 = **192 MB（12.5%）** | 1280 MB | 24 MB | 4 | 28 / 266 | **440** | **1** |
| **AMM 不介入** | 恒 1792 = **0 MB** | 1280 MB | 0 | 0 | 0 / 65 | **0** | 0 |

TP 吞吐（Δt 归一化后的真 TPS）：

| 阶段 | ON | OFF | ON / OFF |
|---|---|---|---|
| tp_warmup | 229 | 616 | **37%** |
| ① stage1 | 363 | 775 | **47%** |
| ② stage2 | 429 | 738 | **58%** |
| ③ stage3 | 633 | 724 | 87% |
| ④ stage4 | 646 | 542 | 119% |
| ⑤ stage5 | 1855 | 1812 | 102% |

gsbench 侧总量：阶段 ①–④ 共 9 分钟，**ON 251,789 ops vs OFF 356,524 ops（OFF 高 41.6%）**；阶段⑤ 2 分钟，ON 279,190 vs OFF 264,734。两组 `errors=0`。

### 问题（1）AP 并发起来，内存有没有借？

| | AMM 介入 | AMM 不介入 |
|---|---|---|
| 共享池是否移动 | **借了，1984 → 1792，共 192 MB（带宽的 12.5%）** | 恒 1792，不动 |
| AP 实际拿到 | `dynamic_used_mb` 峰值 **24 MB**（阶段④ 请求 4096 MB） | **475 MB / 单查询，全内存完成** |
| 排序落盘 | **external merge，Disk 238368 kB** | quicksort，无落盘 |

**判定：不成立。** 池确实动了，但让渡出来的内存没有到达 AP——`dyn_used` 峰值 24 MB 对 4096 MB 的请求，实得约 0.6%。而 AMM 不介入时，AP 无需任何"借"的动作就直接拿到 464 MB 全内存完成排序。

**"借内存"这个动作发生了，"AP 得到内存"这个结果没有发生。**

### 问题（2）借了 TP 内存，有没有托底保护？

| | AMM 介入 | AMM 不介入 |
|---|---|---|
| 地板 | 512 MB | 512 MB |
| 实际最低 `active_mb` | **1792 MB** | 1792 MB |
| 距地板 | **1280 MB（20 个 granule）** | 1280 MB |
| 触地板采样数 | **0** | 0 |
| TP 吞吐（①–④，9 min） | 251,789 ops | **356,524 ops** |
| `drop_ratio` 峰（①②） | **0.62 / 0.42** | **0.067 / 0.029** |
| `tp_guard_hot` 次数（①②） | **31 / 43** | **0 / 0** |

**判定：托底机制从未被触发，且 TP 保护的实际效果是负的。**

共享池最低只到 1792 MB，距地板还有 20 个 granule，地板逻辑一次都没执行到——**它没有被证伪，只是从未有机会运行**。

更值得注意的是保护的方向：AMM 介入时 TP 吞吐**低 41.6%**，`drop_ratio` 高一个数量级（0.62 vs 0.067），`tp_guard_hot` 从 0 次涨到 31–43 次。**AMM 声称要保护的 TP，在它介入后反而更差。**

合理解释是：AP 排序被迫落盘 233 MB，产生的临时文件 I/O 与 TP 的磁盘读争抢（TP 工作集 2.9 GB > 缓冲池，本就是磁盘密集型）。**AMM 通过让 AP 落盘来"节省"内存，代价由 TP 承担。**

### 问题（3）托底保护后 AP 持续增加，是否开启队列保护？

| | AMM 介入 | AMM 不介入 |
|---|---|---|
| 反压次数 | **440** | 0 |
| 入队次数 | **1** | 0 |
| 排队超时 | **106** | 0 |
| 队列长度峰值 | 5 | 0 |
| 入队占反压 | **0.23%** | — |

反压原因构成（仅 ON 组）：

```
resize_cooldown   182     ← 冷却窗口，走不到队列
recovery_cooldown 132     ← 冷却窗口，走不到队列
capacity           87     ← 唯一会入队的分支
tps_guard           1
```

> 关闭组 CSV 的 `last_backpressure_reason` 列显示 `resize_cooldown=719`，那是**开启组遗留的回显值**——该字段未被更新，因为关闭组反压增量为 0。不可作为关闭组发生过反压的证据。

**判定：不成立。** 440 次反压只有 1 次进入队列。代码层原因（`gs_amm.cpp:6553`）：

```c
if (grant_kb > 0) {
    ... admitted = true;
} else if (queue_timeout_ms > 0 && gs_amm_queue_register_locked(state, &queue_ticket)) {
    gs_amm_set_backpressure_reason_locked(state, "capacity");   // ← 只有这一条分支入队
    queued = true;
} else {
    state->ap_queue_timeout_count++;
    gs_amm_set_backpressure_reason_locked(state, guard_fast_block ? block_reason : "capacity");
    backpressure = true;                                        // ← 直接反压，回退 fallback
}
```

`gs_amm_new_ap_block_reason_locked`（`:2211`）返回的 7 种原因中，`resize_cooldown` / `recovery_cooldown` / `tps_guard` / `tp_pressure` / `io_pressure` 全部走 `GsAmmEvaluateAdmission` 的提前反压路径，**到不了队列代码**。本轮此类占反压的 71%。

此外 `gs_amm_admission_failure_policy` 只有两个取值，**没有 `queue`**：

```c
{"fallback", GS_AMM_ADMISSION_FALLBACK, false},
{"error",    GS_AMM_ADMISSION_ERROR,    false},
```

**排队不是准入失败的通用路径**，只有"确实没有容量"才入队；因冷却窗口被拒的请求直接回退到 `fallback_work_mem_kb`。这与 PPT 阶段④"新慢 SQL 进入反压队列"存在语义差异。

### 问题（4）TP 内存托底后，TP 流量增加，会不会增加 TP 共享缓存？

阶段⑤ TP 由 2 worker 阶跃到 8 worker：

| | AMM 介入 | AMM 不介入 |
|---|---|---|
| `buffer_hit` 最低 | **24.4%** | 28.0% |
| `active_mb` 区间 | **恒 1792** | **恒 1792** |
| 是否扩池 | **否** | 否 |

**判定：不成立，且架构上不可能成立。** 三层理由：

**其一，AMM 完全不观测 buffer_hit：**

```
grep -niE "blks_hit|buffer_hit|hit_ratio|hit_rate|cache_hit" gs_amm.cpp  →  0 处匹配
```

AMM 的全部输入信号是 `shared_buffer_physical_read_count`、`ap_temp_spill_bytes`、`tp_baseline_tps` / `tp_recent_tps`。

**其二，物理读只作"刹车"不作"油门"：** 物理读率进入 `gs_amm_compute_io_pressure()`（`:2268`）产出 `io_pressure`，其唯一作用是**阻止借出**。命中率下降 → 物理读上升 → 更不敢借出，方向相反。

**其三，共享池没有"扩张"这个动作：**

```c
// gs_amm.cpp:2902
if (action == GS_AMM_TP_RECOVERY) {
    int available = Max(state->max_mb - state->active_mb, 0);   // 天花板 = 启动时的 shared_buffers
    return Max(Min(available, Max(cfg->resize_rate_limit_mb, granule_mb)), 0);
}
```

唯一能增大 `active_mb` 的是 `TP_RECOVERY`，上限恒为 `max_mb`。**"扩共享池"在实现中只有"把先前借走的还回来"一个含义**，不存在超过 2048 MB 的可能。

### 四项汇总

| PPT step | 验收行为 | AMM 介入 | AMM 不介入 | 判定 |
|---|---|---|---|---|
| ② | AP 并发起来是否借到内存 | 池借 192 MB，AP 实得 24 MB，排序落盘 233 MB | AP 直接得 475 MB 全内存 | **不成立** |
| ③ | 借了 TP 内存是否有托底保护 | 距地板 1280 MB，从未触及；TP 吞吐低 41.6% | TP 吞吐高，guard 全程冷 | **不成立**（机制未触发，效果为负） |
| ④ | AP 持续增加是否开启队列保护 | 反压 440 次仅入队 1 次（0.23%） | 无此机制 | **不成立** |
| ⑤ | TP 增流是否扩共享缓存 | hit 24.4%，池恒 1792 | hit 28.0%，池恒 1792 | **不成立**（架构上不存在该动作） |

---

## 五、为什么内存没借成功 —— 决策树源码分析

### 5.1 直接原因：需求信号被压到借出门槛以下

`BORROW_FROM_BUFFER` 的合法性判据（`gs_amm.cpp:2916`）：

```c
if (action == GS_AMM_BORROW_FROM_BUFFER) {
    if (state->tp_pressure >= cfg->tp_pressure_guard) return "tp_pressure_guard";
    if (state->io_pressure >= cfg->io_pressure_guard) return "io_pressure_guard";
    if (!state->tail_reclaimable)                     return "tail_not_reclaimable";
    if (state->ap_demand_mb <= cfg->deadband_mb)      return "no_demand";     // ← deadband = 32 MB
    if (state->active_mb - state->min_mb <= 0)        return "shared_buffers_min";
    return "";
}
```

而准入路径传给控制器的需求是（`gs_amm_query.cpp:922`、`gs_amm.cpp:6506`/`6415`）：

```c
prediction_mb = Max((gs_amm_native_bound_kb(detail.calibrated_bounds_kb[0]) + 1023) / 1024, 1);
gs_amm_prepare_admission_granules(Max(prediction_mb, (cache_bound_kb + 1023) / 1024));
admission_demand_mb = Max(admission_demand_mb, gs_amm_ap_min_grant_mb);   // = 4
```

**`calibrated_bounds_kb[0]` 来自决策树预测。** 预测值低 → `prediction_mb` 低 → 需求低于 `deadband_mb(32)` → BORROW 判非法 `no_demand`。

### 5.2 决策树预测了多少：0.78 MB

模型是编译进二进制的**静态决策树**（`src/common/backend/utils/mmgr/workmem_dtree_model.cpp`，998 行，文件头注明 `Auto-generated tree inference`，`MEMTUNE_WORKMEM_MODEL_VERSION 1`），19 维特征、三棵树。

`predict_cache_mb` 中有这样一个叶子：

```c
return 0.78155095881963832;      // 单位：MB
```

`0.78155095881963832 MB × 1024 = 800.3 kB` —— 与实测 `observed=800kB` 精确吻合，也与本仓库 README 早先记录的 `dtree_last_feedback_grant_mb = 0.783` 一致。

再往下取整即得授信：

```
prediction_mb = Max((801 + 1023) / 1024, 1) = 1      →  last_grant_mb = 1
```

三个数——**0.783、800 kB、1 MB**——全部指向同一个写死的叶子值。

### 5.3 为什么落在这个叶子上：模型有一处断崖

三棵树的第一层分裂条件：

```c
predict_cache_mb    : if (x[4] <= 5.8494858741760254)   /* max_plan_rows_log10 */
predict_one_pass_mb : if (x[4] <= 5.8494858741760254)   /* max_plan_rows_log10 */
predict_multi_pass_mb: if (x[10] <= 2.8005000352859497) /* current_session_private_memory_mb */
```

`10^5.8495 ≈ 70.7 万行`。两侧叶子值相差两个数量级：

| `predict_cache_mb` 分支 | 条件 | 叶子数 | 值域 | 分布 |
|---|---|---|---|---|
| **左** | ≲ 70.7 万行 | 29 | **0.115 – 7.63 MB** | **20 个低于 0.79 MB** |
| 右 | > 70.7 万行 | 25 | 8.28 – **300.67 MB** | 正常量级 |

本次测试的排序，`EXPLAIN` 实测 `rows=449387`，`log10(449387) = 5.653 < 5.8495` → **落在左子树**，掉进亚 MB 区。

**这不是循环论证。** 449387 行是用 AMM 关闭时校准出的正确区间（`1..112347`）跑出来的真实行数，而该排序实测需要 **475082 kB ≈ 464 MB**（AMM 关闭时全内存完成）。

```
模型预测：0.78 MB
实际需要：464 MB
低估倍数：约 594 倍
```

按 gsbench 的 70%–97% 目标带（358–496 MB）计算，低估区间为 **460 – 640 倍**。

### 5.4 第三棵树整体退化

`predict_multi_pass_mb` 的 18 个叶子全部落在 **0.0196 – 0.0625 MB**：

```
最小 0.0196 MB    最大 0.0625 MB    中位 0.0519 MB
```

无论输入特征如何，它永远返回 20–64 KB，**没有区分能力**。

### 5.5 自我强化闭环

因为 `EXPLAIN ANALYZE` 同样被 AMM 拦截（§3.2），**校准阶段量到的是 AMM 的授信额度，而不是数据库的真实能力**，于是形成闭环：

```
① 决策树预测 0.78 MB → 授信 ~1 MB
        ↓
② gsbench 校准：行数一大就真落盘 → 主动把区间退到 284 行
   （AMM 开启时实测：requested=524288kB observed=800kB observed_percent=0.15 target_met=false）
        ↓
③ 负载在成形之前已被缩水，单查询需求 = max(1, ap_min_grant_mb=4) = 4 MB
        ↓
④ 4 MB ≤ deadband_mb(32) → BORROW 判非法 "no_demand" → 不借
        ↓
⑤ 不借 → 授信依旧不足 → 回到 ①
```

**AMM 既是发放额度的，又是量测需求的，还是判断需求够不够的。** 它在需求成形之前就把需求压了下去，然后据此判定"没有需求"。

这也解释了为什么**加大 AP 压力无效**：压力增加只增加查询条数，而门槛卡在**单查询需求量**上。且需求信号不跨会话累加（`gs_amm.cpp:5980`，全代码无累加），16 个各要 512 MB 的 AP 不会合成一个大需求。

---

## 六、AMM 改变了原生 openGauss 的哪些内存管理行为

### 6.1 介入点：执行器启动钩子

```c
// gs_amm_query.cpp:839
bool GsAmmExecutorStart(QueryDesc *query_desc, int eflags)
{
    if (!gs_amm_enabled) return false;
    ...
    if (!gs_amm_native_auto_mode || !top_level_executor) return false;   // :862 门闩
    if (query_desc->operation != CMD_SELECT) return false;
    if (StreamThreadAmI() || (eflags & EXEC_FLAG_EXPLAIN_ONLY) != 0) return false;
    if (root_plan->total_cost < gs_amm_native_ap_cost_threshold) return false;
    ...
    // ↓ 以下为 AMM 新增行为
    GsAmmBuildWorkMemFeatures(query_desc, &features);      // 扫描计划树取 19 维特征
    GsWorkmemDtreePredictDetail(feature_values, &detail);  // 决策树预测
    GsAmmEvaluateAdmission(prediction_mb);                 // 准入评估
    GsAmmAdmitBounds(..., &admission);                     // 申请授信
}
```

### 6.2 行为差异对照

| 环节 | 原生 openGauss 5.0.2 | gauss-amm |
|---|---|---|
| `work_mem` 语义 | **算子内存预算**，tuplesort 直接读 `u_sess->attr.attr_memory.work_mem` 并据此分配 | **一个申请值**，最终额度由 AMM 决定 |
| 额度来源 | 会话 `SET` 的值（受 `max_process_memory` 约束） | 静态决策树预测 `calibrated_bounds_kb[0..2]` |
| 准入控制 | 无 | `GsAmmEvaluateAdmission` + `GsAmmAdmitBounds`，可拒绝 |
| 被拒后 | 不存在此路径 | `gs_amm_begin_native_fallback()` **改写会话 GUC** |
| 缓冲池大小 | 启动后固定 | granule 级可在 `[min_mb, max_mb]` 借还 |

被拒后的改写是真实的 GUC 写入（`gs_amm_query.cpp:780`）：

```c
state->saved_work_mem_kb = u_sess->attr.attr_memory.work_mem;
effective_work_mem_kb = Min(state->saved_work_mem_kb,
                            Max(gs_amm_fallback_work_mem_kb, 1));   // 只调小，不调大
set_config_option("work_mem", value, PGC_USERSET, PGC_S_SESSION, GUC_ACTION_SAVE, true, ERROR);
```

**即：`SET work_mem='512MB'` 在 AMM 开启时不再是承诺，只是一个请求。**

### 6.3 本次实测暴露的连锁后果

| 后果 | 实测证据 |
|---|---|
| AP 拿不到申请的内存 | 请求 512 MB，授信 ~1 MB；`native_reject_count=442 / eligible=726`（**60.9% 被拒**）；`effective_downgrade_count=477` |
| 排序被迫落盘 | `Sort Method: external merge  Disk: 238368kB`（AMM 关闭时为 `quicksort Memory: 475082kB`） |
| AP 变慢 | 914.9 ms vs 669.5 ms（**+36.7%**） |
| TP 反而变慢 | 251,789 vs 356,524 ops（**−29.4%**，即 OFF 高 41.6%） |
| TP 抖动加剧 | `drop_ratio` 峰 0.62 vs 0.067；`tp_guard_hot` 31–43 次 vs 0 次 |
| 让渡的内存无人使用 | 池借出 192 MB，`dynamic_used_mb` 峰值仅 24 MB |

**AMM 把原生 openGauss "会话声明多少就用多少" 的确定性模型，换成了 "由一个静态决策树预测、再经准入裁决" 的模型。** 当该模型对目标负载低估约 600 倍时，其结果不是"内存调度更优"，而是 AP 与 TP 同时劣化。

---

## 七、数据质量与限制（如实记录）

1. **采样率不对称。** 开启组平均采样间隔 1.70 s（最大 7 s，454 样本），关闭组 1.08 s（最大 2 s，715 样本）。开启组阶段 ③④⑤ 样本数明显偏少（22 / 51 / 61）。
   - **受影响**：事件绝对计数系低估；开启组分阶段 TPS 的估计精度低于关闭组。
   - **不受影响**：`active_mb` 极值（阶段内池值恒定）；累计计数器（按 max−min 读取，精确）；`EXPLAIN` 直接测量；gsbench 侧 operations 总量。
   - 四项验收结论均建立在不受影响的量上。

2. **关闭组的池起点是 1792 而非 2048。** 关闭组紧接开启组运行，池停在开启组结束时的位置。由于 AMM 不介入，池全程未动。故关闭组的"借出深度 0 MB"应理解为"池无移动"，而非"池在满位"。

3. **事件计数须按 `pool_event_id` 去重。** `pool_event_action` 是"最近一次事件"的回显，连续采样会重复计数。本报告所有借/还数字均为去重值。

4. **TPS 须按 Δt 归一化。** 采样器 `tps` 列是采样间隔内的 `Δxact_commit`，间隔 1–7 s 不等，直接算会把采样抖动计入。本报告已归一化。

5. **TPS 抖动 ≤3% 的判据无法判定。** 两组噪声底均远超判据本身（TP 工作集 2.9 GB > 缓冲池 2 GB 使点查大量命中磁盘，虚拟化存储延迟波动大）。这是环境限制，非 AMM 缺陷。**验收①与验收④的前提在本环境相互冲突**：小工作集则 TPS 稳但 `buffer_hit` 恒 100%；大工作集则 `buffer_hit` 可测但 TPS 无法判 3%。

6. **`native_auto_mode=off` 不等于 `gs_amm_enabled=off`。** 前者关闭执行器介入，AMM 的池控制器与遥测仍在（关闭组仍观测到 65 次 `TP_RECOVERY`）。选择前者是为了保持两组遥测可比。若需完全禁用 AMM，应使用后者。

7. **单次 A/B。** 本报告基于一次对照实验，未做重复性验证。

---

## 八、建议

**以下为评估结论的延伸，不构成对被测代码的修改要求。**

1. **决策树模型需重新训练或校准。** 这是最上游、影响最大的一环。当前模型对 45 万行 × 532 字节的排序预测 0.78 MB，实需 464 MB，低估约 600 倍。断崖位于 `max_plan_rows_log10 = 5.8495`（≈70.7 万行），恰好把常见规模的分析型排序划到"小查询"一侧。

2. **`predict_multi_pass_mb` 已退化，应修复或停用。** 18 个叶子全部在 0.0196–0.0625 MB，无区分能力。

3. **准入被拒时不应只调小 work_mem。** 当前 `min(用户值, 回退值)` 使 AP 必然落盘，其 I/O 代价转嫁给 TP。本次实测 TP 吞吐因此下降 29.4%。

4. **`deadband_mb`(32) 应对聚合需求生效，而非单查询需求。** 当前 16 个各要 512 MB 的 AP 不会合成大需求（`gs_amm.cpp:5980` 无累加），加负载无法越过门槛。

5. **队列应成为准入失败的通用路径。** 当前仅 `capacity` 分支入队，冷却类拒绝直接回退，导致 440 次反压仅 1 次入队。`gs_amm_admission_failure_policy` 建议增加 `queue` 取值。

6. **`buffer_hit` 若为验收指标，需先在实现中引入观测。** 目前既无法控制也无法验收。若验收意图是"共享池能超出初始 `shared_buffers` 增长"，需注意该能力当前不存在（`TP_RECOVERY` 上限恒为 `max_mb`）。

7. **若要复验 PPT 完整五阶段链路**，需在低噪声环境（物理机或专用存储）重测，并先完成噪声底测量（CV ≤ 2%）作为硬前置。

---

## 九、证据清单

```
evidence/ab-20260811-172413/
├── amm-ammon-20260811-172413.csv       AMM 介入组采样（459 行，40 列）
├── amm-ammoff-20260811-172413.csv      AMM 不介入组采样（720 行，40 列）
├── probe-ab-workmem.txt                EXPLAIN 直接测量（两模式 Sort 算子内存）
├── prestate-{ammon,ammoff}-*.txt       两组起始池状态
├── poststate-{ammon,ammoff}-*.txt      两组结束池状态与准入计数器
├── timeline-{ammon,ammoff}-*.txt       阶段时间线
├── tp-{ammon,ammoff}-s1234-*.log       两组 TP 主负载（gsbench EVIDENCE）
├── tp-{ammon,ammoff}-s5-*.log          两组阶段⑤ TP
├── ap-{ammon,ammoff}-*.log             AP 持有器输出
├── watchdog-{ammon,ammoff}-*.log       会话与服务器日志看门狗
└── ab-driver.log                       编排驱动日志

scripts/
├── run-ab.sh                 A/B 主编排（五阶段 × 两模式）
├── sample-amm.sh             40 列 CSV 采样器
├── ap-holder.sh              复刻 gsbench 201 的 AP 负载
├── tp-watchdog3.sh           存活看门狗（适配 openGauss 5.0.2 无 backend_type 列）
├── probe-ab-workmem.sh       EXPLAIN 直接测量算子内存
└── analyze-ab.sh             逐阶段并排分析
```

### 复现命令

```bash
# 主实验（约 28 分钟，自动跑完两组并复原 native_auto_mode）
GSBENCH_PASSWORD=... bash scripts/run-ab.sh

# 逐阶段并排分析
bash scripts/analyze-ab.sh

# 直接测量两模式下 Sort 算子实得内存
bash scripts/probe-ab-workmem.sh
```

---

## 十、测试边界声明

本次工作为第三方测试评估。**未修改任何被测代码。**

变更仅一项：GUC `gs_amm_native_auto_mode`（on ↔ off），`sighup` 级，经 `pg_reload_conf()` 生效，不涉及重启或重编译。脚本以 `trap ... EXIT` 保证异常退出时也复原为 `on`，实验结束已确认复原。

报告中列出的缺陷是**评估对象**，不是待办工单。§八 的建议供方案方参考，本次测试不实施任何修复。

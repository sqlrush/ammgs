# AMM 内存池动态调整 —— 开启/关闭对照测试报告

> 被测对象：`gauss-amm` @ `74632f4b89cc6e019b3c07bb860c42622e638025`（基线 openGauss v5.0.2）
> 依据：PPT《内存池动态调整方案验证》阶段 ①–⑤
> 性质：第三方测试评估，**未修改被测代码**

> 实验：2026-08-12 11:41 – 12:08，同一实例连续跑两组，唯一变量 `gs_amm_native_auto_mode`
> 数据：`evidence/ab-20260812-114100/` · 脚本：`scripts/`

---

## 一、测试环境

### 1.1 硬件资源

| 项 | 配置 |
|---|---|
| 载体 | OrbStack machine `gauss-amm-lab` |
| 操作系统 | openEuler 24.03 LTS-SP4 ARM64 |
| CPU | 18 核 |
| 内存 | cgroup 限额 32 GiB |
| 磁盘 | 868 GB（可用 596 GB） |
| 数据库 | openGauss 5.0.2 + AMM，`127.0.0.1:15432` |

### 1.2 数据库参数配置

**原生 openGauss 参数**（AMM 开启与关闭两组完全相同）：

| 参数 | 配置值 | 说明 |
|---|---|---|
| `max_process_memory` | 7424 MB | 进程内存总上限 |
| `enable_memory_limit` | on | 内存保护，已生效 |
| `shared_buffers` | 2048 MB | 共享缓冲池 |
| `cstore_buffers` | 512 MB | 列存缓冲（本测试无列存表） |
| `wal_buffers` | 16 MB | WAL 缓冲 |
| `max_connections` | 200 | 最大连接数 |

**AMM 参数**（仅开启组生效）：

| 参数 | 配置值 | 说明 |
|---|---|---|
| `gs_amm_native_auto_mode` | on / **off** | **本次唯一变量**，off 即恢复原生行为 |
| `gs_amm_shared_buffers_min_mb` | 512 MB | 共享池地板 |
| `gs_amm_granule_size_mb` | 64 MB | 借还的最小单位 |
| `gs_amm_tp_jitter_limit` | 0.30 | TPS 跌幅阈值 |
| `gs_amm_ap_queue_limit` | 16 | 反压队列容量 |
| `gs_amm_ap_queue_timeout_ms` | 5000 | 排队超时 |

### 1.3 内存初始化划分

数据库启动时，`max_process_memory` 被划分为**共享内存**与**动态内存**两部分：

```
┌──────────────────────────────────────────────────────────────┐
│              max_process_memory = 7424 MB                    │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  共享内存段 4429 MB（启动时一次性分配，运行期固定）              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  shared_buffers          2048 MB                       │  │
│  │  ┌──────────────────────────────────────┐              │  │
│  │  │  可迁移带宽 1536 MB（24 granule）      │ ← AMM 可借出 │  │
│  │  ├──────────────────────────────────────┤              │  │
│  │  │  地板 512 MB（8 granule）             │ ← 不可借出   │  │
│  │  └──────────────────────────────────────┘              │  │
│  │                                                        │  │
│  │  cstore_buffers           512 MB                       │  │
│  │  data cache               384 MB                       │  │
│  │  wal_buffers               16 MB                       │  │
│  │  其他共享结构            1469 MB                        │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  动态内存 2134 MB                                             │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  会话上下文、算子 work_mem 从这里支取                     │  │
│  │  空载已用约 542 MB                                      │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

**两点说明：**

1. **共享内存 4429 MB ≠ `shared_buffers` 2048 MB**。后者只占前者的 46%，其余是列存缓冲、数据缓存、缓冲区描述符、锁表等结构。计算内存容量时须用 4429 MB。

2. **动态内存 2134 MB 由 openGauss 派生计算，不是可配置参数**：

   ```
   动态内存 = max_process_memory − 共享内存 − cstore_buffers − 后台预留
            = 7424 − 4429 − 512 − 348 ≈ 2134 MB
   ```

   实例启动日志：`Set max backend reserve memory is: 348 MB, max dynamic memory is: 2134 MB`

### 1.4 由此得到的 AP 容量模型

这是全部测试场景的设计基准。AP 排序的内存有两个来源：

| 来源 | 容量 | 何时使用 | 折合 512 MB 会话数 |
|---|---|---|---|
| **动态内存** | 2134 MB | 常规路径 | **约 4 个** |
| **借来的 granule** | 1536 MB | AMM 从共享池借出后 | **3 个** |
| **合计** | **3670 MB** | | **约 7 个** |

```
会话数：  1    2    3    4  │  5    6    7  │  8 ...
         └──────────────────┘ └────────────┘ └────────
          动态内存 2134 MB      借 1536 MB     无内存可给
          （不需要借）          （必须借）      （只能排队）
                              ↑              ↑
                         开始借的临界点    共享池到达地板
```

**三个关键分界点：**

- **4 个会话**：动态内存用尽，再多就必须向共享池借
- **7 个会话**：可迁移带宽 1536 MB 也用尽，共享池降至 512 MB 地板
- **超过 7 个**：借无可借，只能排队或降级

### 1.5 测试数据

| 表 | 规模 | 用途 |
|---|---|---|
| `accounts` | 1464 万行 | TP 点查目标，工作集 2.9 GB |
| `gsbench.sort_data` | 402.7 万行 | AP 排序目标，单行 532 字节 |

TP 工作集 2.9 GB 大于缓冲池 2 GB，使 `buffer_hit` 能随负载真实波动，step ⑤ 的判据方可观测。

---

## 二、测试场景

五个 step 逐级加压，每个 step 持续 2 分钟。**每个 step 都有一个明确的预期效果**——这些效果就是 AMM 若按设计正常工作应当表现出来的行为，也是本次测试的判据。

### step ① 内存宽裕

| 项 | 值 |
|---|---|
| TP | 2 worker |
| AP | 2 会话 × 128 MB |
| AP 内存需求 | 256 MB |
| 位置 | 远低于动态内存 2134 MB |

**期望效果：** 内存充裕，AP 直接从动态内存获得所需内存，**共享池不发生任何借出**，TP 吞吐不受影响。

本档为基线参照。

---

### step ② 超过 4 个 512 MB 会话 —— 开始借

| 项 | 值 |
|---|---|
| TP | 2 worker |
| AP | **超过 4 个** 512 MB 等效会话 |
| AP 内存需求 | > 2134 MB |
| 位置 | 越过动态内存上限 |

**期望效果：AMM 开始向共享池借内存。**

动态内存已经用尽，新增的 AP 无法从中获得内存。此时 AMM 应当从 `shared_buffers` 借出 granule 交给 AP 使用，表现为：

- `shared_buffers` 从 2048 MB 开始下降
- AP 仍能拿到接近 512 MB 的排序内存，不落盘
- TP 吞吐在缓冲池缩小后仍保持可接受水平

**这是验收 AMM 核心价值的关键档位**——若此处不借，后续各档均无从谈起。

---

### step ③ 达到 7 个 512 MB 会话 —— 借出停止，地板保护生效

| 项 | 值 |
|---|---|
| TP | 2 worker |
| AP | **7 个** 512 MB 等效会话 |
| AP 内存需求 | ≈ 3670 MB |
| 位置 | 动态内存 + 可迁移带宽全部用尽 |

**期望效果：借出停止，`shared_buffers` 停在 512 MB 地板不再下降。**

可迁移带宽 1536 MB 已全部借出，共享池触及 `gs_amm_shared_buffers_min_mb` 下限。此时应当观察到：

- `shared_buffers` 降至 **512 MB** 后**不再继续下降**
- 借出动作停止
- TP 仍能依靠这 512 MB 保底缓存维持运行

**地板保护是 TP 的最后一道防线**——没有它，AP 可以把缓冲池抽干，TP 将因缓存崩塌而不可用。

---

### step ④ 超过 7 个 512 MB 会话 —— 进入队列，保护整体内存

| 项 | 值 |
|---|---|
| TP | 2 worker |
| AP | **超过 7 个** 512 MB 等效会话 |
| AP 内存需求 | > 3670 MB |
| 位置 | 借无可借 |

**期望效果：新到的 AP 进入反压队列，而不是继续挤占内存。**

动态内存与可迁移带宽都已耗尽，系统再无内存可分配。此时 AMM 应当：

- 将新到的 AP 会话**放入队列等待**（`ap_queue_limit=16`，超时 5 秒）
- 而不是让它们无限制申请内存、拖垮整个实例
- 队列的意义在于给内存一个"稍后可得"的机会，同时守住整体内存安全

**这一档检验的是内存耗尽后的兜底行为**：是有序排队，还是静默降级、甚至失控。

---

### step ⑤ TP 流量增加 —— 回补共享池，保住 buffer_hit

| 项 | 值 |
|---|---|
| TP | **2 worker → 8 worker** |
| AP | 保持 step ④ 的会话数不变 |
| 变化方向 | 由 AP 侧加压转为 TP 侧加压 |

**期望效果：`shared_buffers` 回升，`buffer_hit` 得到保护，同时每个 AP 会话的动态内存下降。**

TP 流量放大 4 倍，缓存需求陡增，`buffer_hit` 开始下滑。此时 AMM 应当反向调度：

- 把先前借给 AP 的 granule **收回共享池**，`shared_buffers` 上涨
- `buffer_hit` 因缓冲池恢复而止跌回升
- 代价是**每个 AP 会话可用的动态内存相应降低**，AP 变慢或落盘

**这一档检验调度的双向性**：前四档看"能不能把内存让出去"，这一档看"TP 需要时能不能要回来"。单向让渡不是调度，双向可逆才是。

### 五档汇总

| step | AP 会话数（512 MB 等效） | 所处区间 | 期望效果 |
|---|---|---|---|
| ① | 2 个 × 128 MB | 内存宽裕 | 不借，TP 不受影响 |
| ② | **> 4 个** | 越过动态内存 | **开始借**，`shared_buffers` 下降 |
| ③ | **= 7 个** | 带宽用尽 | **借出停止**，到达 512 MB 地板 |
| ④ | **> 7 个** | 借无可借 | **进入队列**，保护整体内存 |
| ⑤ | 同 ④，TP 2→8 worker | TP 侧加压 | **共享池回升**，`buffer_hit` 保住，AP 内存下降 |

---

## 三、测试脚本

两个负载均基于 **gsbench v1.1.6**（`sqlrush/gsbench`）。

### 3.1 TP 负载：场景 101

模拟 OLTP 点查，为 AMM 提供 TPS 基线，并作为"被保护对象"。

```bash
gsbench run 101 --workers 2 --duration 9m      # step ①~④
gsbench run 101 --workers 8 --duration 2m      # step ⑤
```

启动时对 `accounts` 全表 1464 万行做键采样，保证点查随机命中全表而非热点区：

```
INFO tp_key_sample accounts_rows=14641933 sampled_keys=14641933 stride=1
INFO scenario=tp_cpu workers=2 duration=9m0s rate=unlimited
```

各轮实测 `operations` 20~35 万、`errors=0`。

### 3.2 AP 负载：持有型排序会话

AP 是本次测试的核心工具，它必须真实、稳定地占住内存，否则整个压力模型不成立。

#### 3.2.1 单个会话做什么

```sql
BEGIN;
SET LOCAL work_mem='524288kB';        -- 申请 512 MB
SET LOCAL query_dop=1;                -- 关并行，保证内存可归因

DECLARE apc CURSOR FOR
  SELECT id, sort_key, payload
    FROM gsbench.sort_data
   WHERE dist_key BETWEEN 1 AND <区间>
   ORDER BY payload, sort_key DESC, id;

FETCH 1 FROM apc;                     -- 触发全量排序，内存在此落地
-- 保持游标打开、事务不提交，持续占用
```

**内存能被"占住"的原理**：排序是阻塞算子，要吐出第一行就必须先把全部数据排完。`FETCH 1` 强制 tuplesort 读入全部数据并建立完整排序状态；随后不再 FETCH、不提交事务，游标保持打开，排序内存就不会释放，直到会话结束。

#### 3.2.2 原生 openGauss 下确实能占到接近 512 MB

这是压力模型成立的前提，已用 `EXPLAIN (ANALYZE)` 直接验证：

```
native_auto_mode = off，申请 work_mem = 512 MB

 Sort  (actual time=874.193..896.583 rows=449387 loops=1)
   Sort Key: payload, sort_key DESC, id
   Sort Method: quicksort  Memory: 475082kB          ← 全内存完成，未落盘
 Total runtime: 919.703 ms
```

**实测单会话真实占用 475082 kB ≈ 475 MB，达到申请值 512 MB 的 90.6%，`quicksort` 全内存完成、无落盘。**

区间值由 gsbench 的校准逻辑求得：以二分搜索寻找"能吃满目标 work_mem 且不落盘"的最大行数区间，512 MB 档对应 `dist_key BETWEEN 1 AND 112347`（约 45 万行）。

#### 3.2.3 会话数自动补偿

单会话实得约 463~475 MB 而非 512 MB，存在约 **40~50 MB 缺口**。若按名义值直接换算会话数，实际内存压力会系统性偏低，导致关键分界点跨不过去。

脚本 `scripts/ap-fleet.sh` 对此做自动补偿：**按目标总内存除以实测单会话占用，向上取整得到实际会话数。**

```
实际会话数 = ⌈目标总内存 ÷ 单会话实测占用⌉
```

**测量在原生模式下进行，且只做一次，两组共用同一组会话数。** 这是对照实验的必要条件，原因有二：

1. **AMM 开启时测量无效。** 该模式下排序会落盘，`EXPLAIN` 输出的是 `Disk: NkB` 而非 `Memory: NkB`，测不到真实驻留内存。实测该模式下测量函数返回 0。
2. **两组必须跑相同的会话数。** 若各自测量，两组会得到不同的并发数，就不再是对照实验。

本次实测与据此计算的会话数：

```
原生模式实测单会话占用 = 463 MB
```

| 场景目标 | 目标总内存 | 名义会话数 | **实际启动会话数** |
|---|---|---|---|
| 越过动态内存（step ②） | 2134 MB | 5 个 | **5 个** |
| 用尽可迁移带宽（step ③） | 3670 MB | 8 个 | **8 个** |
| 借无可借（step ④） | 5000 MB | 10 个 | **11 个** |

测量值不写死在脚本里，每次实验开始时重新测，以适应数据分布或环境变化。

这样可确保三个关键分界点（越过动态内存、用尽带宽、借无可借）都被真实跨越，而不是停在临界值以下。

### 3.3 编排

`scripts/run-ab.sh` 依次执行两组：先 `gs_amm_native_auto_mode=on`，静默 30 秒后切 `off`，两组使用完全相同的五阶段编排与负载参数。

采样器每秒记录一次 AMM 状态与数据库统计，输出 40 列 CSV；另有看门狗记录会话与服务器日志。

---

## 四、测试结果

> 实验：2026-08-12 11:41 – 12:08，STAMP `20260812-114100`
> 会话数：实测单会话 463 MB → step② 5 个 / step③ 8 个 / step④⑤ 11 个（两组共用）

每个 step 分三部分：**测试目标** → **未开启 AMM** → **开启 AMM**。

### 4.0 先看一个贯穿全局的对照

同一条排序 SQL、同样 449387 行、同一执行计划，只切 `gs_amm_native_auto_mode`：

| | 未开启 AMM | 开启 AMM |
|---|---|---|
| Sort Method | `quicksort` | `external merge` |
| 内存 / 磁盘 | **Memory 475082 kB**（464 MB，全内存） | **Disk 238376 kB**（落盘 233 MB） |
| 单查询耗时 | **667.9 ms** | **816.2 ms**（慢 22%） |
| AMM 授信 | — | `last_grant_mb = 6` |

**AP 会话申请 512 MB，开启 AMM 后实得授信 6 MB，被迫落盘。** 这个差异贯穿后续所有 step。

---

### step ① 内存宽裕（2 会话 × 128 MB）

**测试目标：** 内存充裕，AP 直接从动态内存取得所需内存，**共享池不发生借出**，TP 不受影响。

**未开启 AMM：目标达成。**

| 指标 | 值 |
|---|---|
| `shared_buffers` | 恒 1984 MB，无任何变动 |
| AP | 直接获得内存，无落盘 |
| TP 吞吐 | 633 TPS |
| `buffer_hit` 均值 | 87.4% |

**开启 AMM：未达成——本不该借，却在反复借还。**

共享池全程振荡：

```
SB=1792 → 1856 → 1920   （回收）
SB=1856  BORROW_FROM_BUFFER   ← 借出 1 个 granule
SB=1920  TP_RECOVERY          ← 随即收回
SB=1856  BORROW_FROM_BUFFER   ← 再借
SB=1920  TP_RECOVERY          ← 再收回
SB=1856  BORROW_FROM_BUFFER   ← 三借
SB=1920  TP_RECOVERY          ← 三收
```

| 指标 | 值 |
|---|---|
| 借出事件 | 7 次（本档不应有） |
| `dynamic_used_mb` 峰值 | 2 MB |
| TP 吞吐 | 627 TPS（与关闭组持平） |
| 反压 | 37 次，排队超时 16 次 |

内存宽裕的档位出现了 37 次反压和 3 轮借还振荡，属于**不必要的调度动作**。

---

### step ② 超过 4 个 512 MB 会话（5 会话，需求 2315 MB）

**测试目标：** 需求 2315 MB 已越过动态内存 2134 MB，**AMM 应开始向共享池借内存**，`shared_buffers` 从 2048 MB 下降，AP 仍能拿到接近 512 MB 不落盘。

**未开启 AMM：无借出机制，AP 靠落盘消化超额需求。**

| 指标 | 值 |
|---|---|
| `shared_buffers` | 恒 1984 MB |
| AP | 超出动态内存的部分落盘，无报错 |
| TP 吞吐 | 670 TPS |
| `buffer_hit` 均值 | 87.2% |

**开启 AMM：未达成——共享池纹丝不动。**

| 指标 | 值 |
|---|---|
| `shared_buffers` | **恒 1920 MB，全程零变动** |
| 借出深度 | **0 MB** |
| `dynamic_used_mb` 峰值 | **12 MB**（需求 2315 MB） |
| AMM 观测到的 AP 并发 | **2**（实际 5 个会话） |
| TP 吞吐 | 720 TPS |
| 反压 / 排队超时 | 35 / 36 次 |

**这是最关键的一档。** 需求已明确越过动态内存上限，按设计此时必须借出，但共享池一格未动，动态池只用掉 12 MB。AMM 观测到的活跃 AP 只有 2 个——**另外 3 个会话根本没有进入 AMM 的记账**。

---

### step ③ 达到 7 个 512 MB 会话（8 会话，需求 3704 MB）

**测试目标：** 需求已用尽"动态内存 + 全部可迁移带宽"，`shared_buffers` 应降至 **512 MB 地板**并停止下降，地板保护生效。

**未开启 AMM：无地板概念，继续靠落盘消化。**

| 指标 | 值 |
|---|---|
| `shared_buffers` | 恒 1984 MB |
| TP 吞吐 | 546 TPS |
| `buffer_hit` 均值 | 87.7% |
| 错误 | 0 |

**开启 AMM：未达成——距地板 1408 MB。**

| 指标 | 值 |
|---|---|
| `shared_buffers` | **恒 1920 MB** |
| 距地板 512 MB | **1408 MB（22 个 granule）** |
| 借出深度 | **0 MB** |
| `dynamic_used_mb` 峰值 | 12 MB（需求 3704 MB） |
| TP 吞吐 | 739 TPS |
| 反压 / 排队超时 | 35 / 39 次 |

地板保护**未被触发**——不是它失效，而是压力从未推到地板附近。共享池在 8 个 512 MB 会话面前保持 1920 MB 不动。

---

### step ④ 超过 7 个 512 MB 会话（11 会话，需求 5093 MB）

**测试目标：** 动态内存与可迁移带宽都已耗尽，新到的 AP **应进入反压队列**，保护整体内存。

**未开启 AMM：无队列机制，全部会话靠落盘完成，未出现错误。**

| 指标 | 值 |
|---|---|
| `shared_buffers` | 恒 1984 MB |
| 反压 / 入队 | 0 / 0（无此机制） |
| AP 错误 | **0 条** |
| TP 吞吐 | 483 TPS |

11 个会话共需 5093 MB，而动态内存仅 2134 MB。原生 openGauss 的处理方式是**让超出部分落盘**，全部会话正常完成、无报错——这是它在内存不足时的既有兜底。

**开启 AMM：基本未达成——反压 48 次仅入队 1 次。**

| 指标 | 值 |
|---|---|
| 反压次数 | **48** |
| 入队次数 | **1**（占反压 2.1%） |
| 排队超时 | 39 次 |
| 队列长度峰值 | 8 |
| TP 吞吐 | 748 TPS |

全程反压原因构成：

```
capacity            164     ← 唯一会入队的分支
resize_cooldown      88     ← 冷却窗口，走不到队列
recovery_cooldown    80     ← 冷却窗口，走不到队列
```

**超过一半的反压（168/332）因冷却窗口被直接拒绝，根本到不了队列。**

---

### step ⑤ TP 流量增加（TP 2→8 worker，AP 保持 11 会话）

**测试目标：** TP 流量放大 4 倍，`buffer_hit` 下滑，AMM 应**把借出的内存收回共享池**，`shared_buffers` 上涨保住 `buffer_hit`，同时每个 AP 会话的动态内存下降。

**未开启 AMM：共享池固定，`buffer_hit` 自然下滑。**

| 指标 | 值 |
|---|---|
| `shared_buffers` | 恒 1984 MB |
| `buffer_hit` 最低 | **17.1%** |
| TP 吞吐 | 2218 TPS |
| TP operations（2 min） | 304,010 |

**开启 AMM：部分达成——共享池确实回升，但幅度有限。**

| 指标 | 值 |
|---|---|
| `shared_buffers` | **1920 → 1984 MB（+64 MB）** |
| `buffer_hit` 最低 | **21.5%** |
| TP 吞吐 | 1881 TPS |
| TP operations（2 min） | 276,463 |

这是五档中**唯一观察到符合预期方向动作**的一档：共享池确实随 TP 加压而回升了 1 个 granule，`buffer_hit` 最低点也略优于关闭组（21.5% vs 17.1%）。但由于此前从未借出过多少，可回收的量本就有限。

---

### 4.6 五档汇总

| step | 测试目标 | 未开启 AMM | 开启 AMM | 达成 |
|---|---|---|---|---|
| ① | 不借，TP 不受影响 | SB 恒 1984，无动作 | SB 在 1856↔1920 振荡，借还 3 轮，反压 37 次 | **否**（多余动作） |
| ② | 越过动态内存 → 开始借 | SB 恒 1984，超额落盘 | **SB 恒 1920，借出 0 MB**，dyn_used 12 MB | **否** |
| ③ | 达到 7 个 → 到 512 地板 | SB 恒 1984 | **SB 恒 1920，距地板 1408 MB** | **否** |
| ④ | 超过 7 个 → 进队列 | 无机制，落盘完成，0 错误 | 反压 48 次仅入队 1 次 | **基本否** |
| ⑤ | TP 加压 → 共享池回升 | SB 恒 1984，hit 低 17.1% | **SB 1920→1984**，hit 低 21.5% | **部分是** |

### 4.7 性能对照

**AP 侧：开启 AMM 后显著变差。**

| | 未开启 AMM | 开启 AMM |
|---|---|---|
| 单会话排序内存 | 464 MB（全内存） | 落盘 233 MB |
| 单查询耗时 | 667.9 ms | **816.2 ms（+22%）** |

**TP 侧：分阶段互有高低。**

| 阶段 | 未开启 AMM | 开启 AMM | 差异 |
|---|---|---|---|
| ① | 633 | 627 | −1% |
| ② | 670 | 720 | +7% |
| ③ | 546 | 739 | +35% |
| ④ | 483 | 748 | +55% |
| ⑤ | 2218 | 1881 | −15% |
| **operations（①–④，9 min）** | 295,403 | **315,007** | **+6.6%** |
| **operations（⑤，2 min）** | **304,010** | 276,463 | −9.1% |

AP 压力越大（step ③④），开启 AMM 时 TP 反而越快。合理解释是：**AMM 把 AP 的内存申请压到 6 MB，AP 立即落盘，不再与 TP 争抢内存**——TP 的收益来自 AP 被"饿死"，而非来自内存的有效调度。step ⑤ TP 自身成为主压力源时，这一收益消失并转为劣势。

**两组均未出现 AP 报错**（各 0 条），说明两种模式下内存不足都以落盘方式降级，未造成查询失败。

### 4.8 数据质量说明

开启组的采样密度低于关闭组（各 step 样本数 22~69 对 110~134），原因是 AMM 介入使采样连接的响应变慢。

- **不受影响**：`shared_buffers` 极值（各 step 内池值恒定）、累计计数器（反压/入队/超时按增量读取）、`EXPLAIN` 直接测量、gsbench operations 总量
- **受影响**：开启组分阶段 TPS 均值的估计精度低于关闭组，表 4.7 中各 step 的 TPS 差异应视为趋势而非精确值；operations 总量不受此影响

本报告的达成判定均建立在不受影响的量上。

---

## 五、源码层面的原因分析

第四章的五个未达成现象，在源码中都能找到确切成因。本章逐一对应。

### 5.1 现象与根因对照

| 第四章观察到的现象 | 根因 | 源码位置 |
|---|---|---|
| 申请 512 MB 实得授信 6 MB，排序落盘 | 授信由静态决策树给出，对本负载低估约 600 倍 | `workmem_dtree_model.cpp:149` |
| 授信小则排序内存必然小 | AMM 对算子内存**只减不增** | `tuplesort.cpp:963` `:574` |
| step② 越过动态内存但共享池零变动 | 借出触发条件是"空闲链表为空"，不是"需求超过供给" | `gs_amm.cpp:6424` |
| 5→8→11 会话加压无效 | 需求信号是**单查询**的，不跨会话累加 | `gs_amm.cpp:6506` `:5980` |
| 需求被判为"无需求" | 塌缩后单查询需求 4 MB ≤ `deadband_mb` 32 | `gs_amm.cpp:2924` |
| AMM 只观测到 2 个活跃 AP（实际 5~11 个） | 回退路径不计入 `active_ap_count` | `gs_amm_query.cpp:780` vs `gs_amm.cpp:6555` |
| step① 内存宽裕却借还振荡 | 自动控制器每拍传 `demand=0`，回收成唯一正分动作 | `gs_amm.cpp:5510` |
| 借出后立即被收回 | 借要过 5 道闸，还只过 1 道，回收判据不检查 AP 是否仍需要 | `gs_amm.cpp:2914` vs `:2916` |
| step④ 反压 48 次仅入队 1 次 | 冷却类拒绝走提前反压路径，到不了队列 | `gs_amm.cpp:2211` `:6553` |
| step⑤ 共享池只回升 64 MB | AMM 不观测 `buffer_hit`；`TP_RECOVERY` 上限恒为 `max_mb` | `gs_amm.cpp:2902` |

### 5.2 根因一：授信额度由静态决策树给出，对本负载低估约 600 倍

AP 能拿到多少内存，由一棵**编译进二进制的静态决策树**决定（`src/common/backend/utils/mmgr/workmem_dtree_model.cpp`，文件头注明 `Auto-generated tree inference`，19 维特征）。

本次负载命中的叶子：

```c
// workmem_dtree_model.cpp:149
return 0.78155095881963832;      // 单位 MB
```

`0.78155095881963832 MB × 1024 = 800.3 kB`。向上取整后即为授信：

```c
// gs_amm_query.cpp:922
prediction_mb = Max((gs_amm_native_bound_kb(calibrated_bounds_kb[0]) + 1023) / 1024, 1);
```

实测 `last_grant_mb = 6`，与该量级一致。

**为什么落在这个叶子上——模型第一层有一处断崖：**

```c
// workmem_dtree_model.cpp:44 与 :420
if (x[4] <= 5.8494858741760254)   /* max_plan_rows_log10 */
```

`10^5.8495 ≈ 70.7 万行`。两侧叶子值相差两个数量级：

| 分支 | 条件 | 叶子数 | 值域 |
|---|---|---|---|
| **左** | ≲ 70.7 万行 | 29 | **0.115 – 7.63 MB**，其中 20 个低于 0.79 MB |
| 右 | > 70.7 万行 | 25 | 8.28 – **300.67 MB** |

本次排序 `EXPLAIN` 实测 `rows=449387`，`log10(449387) = 5.653 < 5.8495` → **落在左子树**。

而该排序在原生模式下实测需要 **464 MB**（`quicksort Memory: 475082kB`）：

```
模型预测   0.78 MB
实际需要   464 MB
低估倍数   约 600 倍
```

**这不是负载被缩小造成的**——449387 行是用原生模式校准出的正确区间跑出的真实行数。

**第三棵树已退化：** `predict_multi_pass_mb` 的 18 个叶子全部落在 **0.0196 – 0.0625 MB**，无论输入什么特征都返回 20~64 KB，不具备区分能力。

### 5.3 根因二：AMM 对算子内存只减不增

即使 `work_mem` 设为 512 MB，最终生效值也被授信压下去，且**只会往下压**：

```c
// tuplesort.cpp:963  创建排序时
if (amm_grant_kb > 0)
    workMem = Min(workMem, (int64)amm_grant_kb);      // 只取小值

// tuplesort.cpp:574  运行中每次检查内存
static void ApplyGsAmmEffectiveSortGrant(Tuplesortstate* state)
{
    ...
    if (grant_bytes >= state->allowedMem)
        return;                                       // 授信 ≥ 现额度 → 不做任何调整
    state->allowedMem = grant_bytes;                   // 只会往下压
}
```

**AMM 从不把 `work_mem` 调高。** 因此 §5.2 的低估会一比一传导为排序可用内存的减少，直接导致落盘。

准入失败时更直接——改写会话 GUC：

```c
// gs_amm_query.cpp:780  gs_amm_begin_native_fallback()
effective_work_mem_kb = Min(state->saved_work_mem_kb, Max(gs_amm_fallback_work_mem_kb, 1));
set_config_option("work_mem", value, PGC_USERSET, PGC_S_SESSION, GUC_ACTION_SAVE, true, ERROR);
```

即 `SET work_mem='512MB'` 在 AMM 开启时不再是承诺，只是一个申请。

### 5.4 根因三：借出的触发条件与需求信号

这两处共同解释了 step②③④「加压无效」。

**其一，借出触发条件是"空闲链表为空"，而非"需求超过供给"：**

```c
// gs_amm.cpp:6424
if (free_granule_mb == 0 && block_reason[0] == '\0')
    gs_amm_controller_step_internal(admission_demand_mb, tp_pressure, io_pressure, NULL, 0);
```

只要空闲链表里还剩 1 个 granule，**无论有多少 AP 在等内存，都不会触发借出**。第四章 step②③ 中 `free_gr` 长期为 1~2，正对应此处。

**其二，需求信号是单查询的，不跨会话累加：**

```c
// gs_amm.cpp:6506  准入路径传的是本查询自己的需求
gs_amm_prepare_admission_granules(Max(prediction_mb, (cache_bound_kb + 1023) / 1024));

// gs_amm.cpp:6415  再抬到最小授信
admission_demand_mb = Max(admission_demand_mb, gs_amm_ap_min_grant_mb);   // = 4

// gs_amm.cpp:5980  控制器状态直接取该单值，全代码无任何累加
obs.ap_demand_mb    = effective_ap_demand_mb;
state0.ap_demand_mb = obs.ap_demand_mb;
```

**11 个各要 512 MB 的会话不会合成一个 5632 MB 的需求**，控制器每次只看到其中一个查询的需求。这就是为什么会话数从 5 提到 11，借出深度毫无变化。

**其三，塌缩后的需求低于死区，被判为"无需求"：**

```c
// gs_amm.cpp:2924
if (state->ap_demand_mb <= cfg->deadband_mb)
    return "no_demand";                               // deadband_mb = 32
```

授信塌缩后单查询需求 `max(1, ap_min_grant_mb=4) = 4 MB ≤ 32 MB`，`BORROW` 被判为非法。

### 5.5 根因四：为什么 AMM 只观测到 2 个活跃 AP

第四章 step②~④ 中，实际启动 5~11 个 AP 会话，但 `active_ap_count` 峰值始终是 2。

原因是**只有授信成功的会话才被计入**：

```c
// gs_amm.cpp:6555  授信成功路径
if (grant_kb > 0) {
    state->dynamic_used_mb += grant_mb;
    state->active_ap_count++;                         // ← 仅此处递增
    ...
}
```

而走回退路径的会话不计入：

```c
// gs_amm_query.cpp:780  gs_amm_begin_native_fallback()
state->active = true;
state->fallback = true;
state->selected_grant_mode = GS_AMM_NATIVE_GRANT_MODE_NONE;   // 无 grant，不计数
```

**即：拿不到授信的 AP 会话，在 AMM 的账本里等于不存在。** 它们既不算"已满足的需求"，也不算"待满足的需求"，直接从需求侧消失——这进一步加剧了 §5.4 的需求低估。

### 5.6 根因五：自动控制器恒传 demand=0，借与还判据不对称

这解释了 step① 中「内存宽裕却反复借还」的振荡。

**自动控制器每拍都把需求写死为 0：**

```c
// gs_amm.cpp:5479  gs_amm_autorun_controller_from_metrics()
active_ap_count = state->active_ap_count;      // 读了
dynamic_used_mb = state->dynamic_used_mb;      // 读了
ap_queue_len    = state->ap_queue_len;         // 读了
if (!tp_guard_hot && !io_guard_hot && active_ap_count == 0 && dynamic_used_mb == 0 &&
    ap_queue_len == 0 && reclaiming_granules == 0) {
    SpinLockRelease(&state->mutex); return;     // ← 三个信号只当「要不要跑这一拍」的门闩
}
state->auto_controller_step_count++;
SpinLockRelease(&state->mutex);

gs_amm_controller_step_internal(0, tp_pressure, io_pressure, NULL, 0);   // ← 需求硬编码 0
```

三个需求信号被读取后，仅用于判断是否执行本拍，**跑起来后需求一律传 0**。

**而借与还的合法性判据严重不对称：**

```c
// gs_amm.cpp:2914  还 —— 1 道闸
if (action == GS_AMM_TP_RECOVERY)
    return state->active_mb < state->max_mb ? "" : "at_max";

// gs_amm.cpp:2916  借 —— 5 道闸
if (action == GS_AMM_BORROW_FROM_BUFFER) {
    if (state->tp_pressure >= cfg->tp_pressure_guard) return "tp_pressure_guard";
    if (state->io_pressure >= cfg->io_pressure_guard) return "io_pressure_guard";
    if (!state->tail_reclaimable)                     return "tail_not_reclaimable";
    if (state->ap_demand_mb <= cfg->deadband_mb)      return "no_demand";
    if (state->active_mb - state->min_mb <= 0)        return "shared_buffers_min";
    return "";
}
```

**回收的合法性判据里，没有任何一项检查「AP 是否还需要这块内存」**，唯一条件是"还没回到上限"。

叠加评分——回收收益 `recovered × tp_pressure/100 × 1.2`，而 `OBSERVE` 恒为 0 分。混合负载下 `drop_ratio > 0` 几乎恒成立，因此：**只要 BORROW 因 `demand=0` 被判非法，回收就是唯一正分动作，每一拍都会执行。**

这正是 step① 观察到的形态：借出 1 个 granule → 下一拍自动控制器传 0 → 回收 → 再借 → 再收。

### 5.7 根因六：队列不是准入失败的通用路径

step④ 反压 48 次仅入队 1 次，源码中只有一条分支能进队列：

```c
// gs_amm.cpp:6553
if (grant_kb > 0) {
    ... admitted = true;                                          // 正常授予
} else if (queue_timeout_ms > 0 && gs_amm_queue_register_locked(state, &queue_ticket)) {
    gs_amm_set_backpressure_reason_locked(state, "capacity");     // ← 唯一入队分支
    queued = true;
} else {
    state->ap_queue_timeout_count++;
    gs_amm_set_backpressure_reason_locked(state, guard_fast_block ? block_reason : "capacity");
    backpressure = true;                                          // ← 直接反压，回退 fallback
}
```

而 `gs_amm_new_ap_block_reason_locked` 返回的 7 种原因中，多数走 `GsAmmEvaluateAdmission` 的提前反压路径，**根本到不了队列代码**：

```c
// gs_amm.cpp:2211
if (state->tp_generation_exhausted)          return "telemetry_generation_exhausted";
if (state->cooldown_until > now)             return "resize_cooldown";      // ← 不入队
if (gs_amm_tp_drop_guard_hot_locked(state))  return "tps_guard";            // ← 不入队
if (gs_amm_io_guard_hot_locked(state))       return "io_pressure";          // ← 不入队
if (gs_amm_recovery_cooldown_hot_locked(...)) return "recovery_cooldown";   // ← 不入队
...
```

第四章实测的反压原因构成正好印证：

```
capacity            164     ← 唯一会入队的分支
resize_cooldown      88     ← 冷却窗口，不入队
recovery_cooldown    80     ← 冷却窗口，不入队
```

**168 / 332 = 51% 的反压因冷却窗口被直接拒绝。**

此外 `gs_amm_admission_failure_policy` 只有两个取值，**没有 `queue`**：

```c
{"fallback", GS_AMM_ADMISSION_FALLBACK, false},
{"error",    GS_AMM_ADMISSION_ERROR,    false},
```

即排队不是准入失败的通用策略，只有"确实没有容量"才入队；因冷却被拒的请求直接回退到 `fallback_work_mem_kb`。这与 step④ 期望的"新慢 SQL 进入反压队列"存在语义差异。

### 5.8 根因七：AMM 感知不到 buffer_hit，也感知不到进程内存

**其一，全代码零处引用 `buffer_hit`：**

```
grep -niE "blks_hit|buffer_hit|hit_ratio|hit_rate|cache_hit" gs_amm.cpp  →  0 处匹配
```

AMM 的全部输入信号是 `shared_buffer_physical_read_count`、`ap_temp_spill_bytes`、`tp_baseline_tps` / `tp_recent_tps`。物理读率只进入 `io_pressure`，而 `io_pressure` 的唯一作用是**阻止借出**——命中率下降会让它更不敢借，方向相反。

**其二，共享池没有"扩张"这个动作。** 唯一能增大 `active_mb` 的是 `TP_RECOVERY`，其步长上限恒为 `max_mb`：

```c
// gs_amm.cpp:2902
if (action == GS_AMM_TP_RECOVERY) {
    int available = Max(state->max_mb - state->active_mb, 0);   // 天花板 = 启动时的 shared_buffers
    return Max(Min(available, Max(cfg->resize_rate_limit_mb, granule_mb)), 0);
}
```

**"回补共享池"在实现中只有"把先前借走的还回来"一个含义**，不存在超过初始 `shared_buffers` 的可能。step⑤ 只回升 64 MB，是因为此前本就只借出了这么多。

**其三，AMM 不读 `max_process_memory`，也不识别 cgroup。** 它的内存感知只来自 `/proc/meminfo`：

```c
// gs_amm_query.cpp:631
static void gs_amm_collect_system_memory(MemTuneWorkMemFeatures &features)
{
    FILE *file = AllocateFile("/proc/meminfo", "r");
    ...  MemTotal / MemAvailable  ...
}
```

本环境 VM 有 32 GiB 内存，在 AMM 眼里内存永远充裕——**它对数据库自身的动态内存是否吃紧毫无感知**。

### 5.9 自我强化闭环

上述根因不是彼此独立的，它们构成一个闭环：

```
① 决策树给出 0.78 MB 授信（低估 600 倍）
        ↓
② AMM 只减不增，排序实际可用内存被压到 6 MB
        ↓
③ 单查询需求 = max(1, ap_min_grant_mb=4) = 4 MB
        ↓
④ 4 MB ≤ deadband_mb(32) → BORROW 判非法「no_demand」
        ↓
⑤ 不借 → 空闲链表非空 → 连借出的触发条件也不满足
        ↓
⑥ 拿不到授信的会话走回退路径，不计入 active_ap_count
        ↓
   需求在账本上进一步消失 → 回到 ①
```

**AMM 既是发放额度的，又是量测需求的，还是判断需求够不够的。** 它在需求成形之前就把需求压了下去，然后据此判定"没有需求"。

这解释了为什么**提高压力无效**：加大并发只增加查询条数，而所有门槛卡的都是**单查询需求量**。第四章中会话数从 5 提到 11，借出深度始终为 0，正是这个闭环的直接后果。

### 5.10 小结

| 层次 | 问题 | 影响的 step |
|---|---|---|
| **模型层** | 决策树对本类排序低估约 600 倍；第三棵树已退化 | 全部 |
| **执行层** | AMM 对算子内存只减不增；准入失败改写会话 `work_mem` | 全部 |
| **控制层** | 借出触发条件是空闲链表为空；需求不跨会话累加；死区 32 MB | ②③④ |
| **调度层** | 自动控制器恒传 `demand=0`；借 5 闸 / 还 1 闸不对称 | ① |
| **准入层** | 队列非通用路径，冷却类拒绝直接回退 | ④ |
| **感知层** | 不观测 `buffer_hit`，不读 `max_process_memory`，只看 `/proc/meminfo` | ⑤ |

**最上游、影响面最大的是模型层**：若授信正常，②③ 两档的借出与地板行为有机会成立。但 ④（队列）与 ⑤（回补）的问题独立于授信，属于准入分支设计与感知信号缺失，需单独处理。

---

## 六、测试边界声明

本次工作为第三方测试评估。**未修改任何被测代码。**

变更仅两项，均为配置：

1. `max_process_memory` 由 4 GB 调整为 7424 MB，使 openGauss 内存保护得以初始化（`enable_memory_limit` 生效）。两组同等适用。
2. `gs_amm_native_auto_mode` 在两组间切换（on / off），即本次唯一变量。脚本以 `trap ... EXIT` 保证异常退出时复原为 `on`。

报告中列出的缺陷是**评估对象**，不是待办工单。本次测试不实施任何修复。

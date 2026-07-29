# ammgs

gauss-amm 相对原生 openGauss 5.0.2 的源码分析、ARM64 构建、OrbStack 部署与针对性测试资料。

## 结论

该分支实现了真实的 granule 级 buffer/AP 内存借还、查询 admission、专属 allocator、决策树预测和 TP/I/O 保护，不是只有 GUC 声明的空壳。

当前版本仍属于工程原型，不建议生产启用：

- `feedback-only` 可复现数据库级 SIGSEGV，根因已定位为错误的 plan walker context。
- 普通 dtree 路径没有执行文档声明的 4 MB 最小 grant；实测 0.783 MB grant 独占 64 MB granule。
- 内存特征读取 `/proc/meminfo`，不识别 cgroup 限额。
- `gs_guc` 白名单、文档、状态语义和默认测试调度存在漂移。

完整结论见 [源码对比与实测报告](docs/gauss-amm-analysis-report.md)。

## 基线

| 对象 | 精确版本 |
|---|---|
| gauss-amm | `74632f4b89cc6e019b3c07bb860c42622e638025` |
| openGauss 官方基线 | `v5.0.2` / `48a25b114825483bc8f2b8b88ee7366e4dc9f875` |
| 测试平台 | openEuler 24.03 LTS-SP4 ARM64 |
| OrbStack machine | 8 vCPU、32 GiB memory limit、128 GiB disk cap |

## 目录

```text
docs/
  gauss-amm-analysis-report.md       中文源码对比、构建部署、风险与建议
evidence/
  upstream-v5.0.2-name-status.diff  98 个差异文件的机器可读清单
  upstream-v5.0.2.stat              diff 统计
  gs_amm_*.actual                   各测试原始 SQL 输出
  feedback-only-sigsegv-ffic.log    崩溃现场与调用栈
  build-*.log                       两次 ARM64 构建驱动日志
  server-log-tail.log               最终服务器日志尾部
scripts/
  start-gauss-amm.sh                VM 内启动辅助脚本
  stop-gauss-amm.sh                 VM 内停止辅助脚本
  configure-gauss-amm.sql           安全默认配置
SHA256SUMS                          仓库资料文件校验值
```

## 测试结果

| 测试 | 结果 |
|---|---|
| 两轮 50,000 行 × 1 KB 外排 | 通过 |
| 空闲 AP granule 回收 | 通过 |
| native allocator-only | 通过 |
| native dtree | 查询正确；暴露最小 grant/碎片 P1 |
| feedback-only | 失败；触发 gaussdb SIGSEGV，P0 |
| TP 热保护 | 通过 |
| 崩溃后恢复与安全状态复核 | 通过 |

## 范围说明

本仓库不包含私有 Gitee 源码、源码归档、数据库密码或邀请链接。源码行号均以报告顶部记录的精确 commit 为准；`evidence/` 中保留了复核结论所需的差异清单、构建日志和原始测试输出。

# BeaconAgentKit v0.2 Goal Mode Prompt

请启动目标模式，持续完成 BeaconAgentKit v0.2 独立 Agent 平台以及见好的首个端到端接入，直到所有可在当前环境完成的开发、测试、回归和证据报告都完成。

开始前必须完整阅读：

1. /Users/zhanggengying/Documents/beacon-agent-kit/docs/beacon-agent-platform-v0.2-design.md
2. /Users/zhanggengying/Documents/beacon-agent-kit/docs/plans/2026-08-08-beaconagentkit-v0-2-platform-implementation.md
3. /Users/zhanggengying/Documents/健身助手/AGENTS.md
4. 两个仓库各自的 RTK.md、当前 git status、最近提交和已有测试约束。

执行要求：

- 以实施计划中的 6 个里程碑、22 个任务为唯一主线，严格按顺序执行并持续更新计划复选框和目标状态。
- 先建立基线，再用 TDD 完成每个任务；每个任务都要先写失败测试、实现最小完整功能、运行相应测试、形成边界清晰的提交。
- BeaconAgentKit 必须保持独立、开源、领域无关，不能引用见好业务类型、业务文案、用户数据或健康数据。
- 见好只通过 Capability Pack、设备工具桥和渲染器目录接入；训练、饮食、睡眠、HealthKit、本地存储、业务卡片、私教知识内容和最终写入继续由见好拥有。
- 服务端只负责模型调用、能力注册、路由和编排。用户数据查询与写入必须在设备本机执行，只向服务端返回经过约束和脱敏的最小 Observation。
- 意图层必须实现确定性上下文、能力召回、受约束重排、策略过滤和迭代 Agent Loop，不能退化成一次分类后把全部数据一次性喂给模型。
- AG-UI 文本、Activity、Tool 和 A2UI Surface 必须在生成过程中流式渲染；Markdown 不能等完整响应结束才正确排版；有已注册业务卡片时不能回退为 Markdown 表格。
- 首个完整验收场景是“安排一下明天练肩”：逐步查询本机上下文，生成可编辑动作组草稿，支持替换、组数调整和排序，确认后写入明天而不是今天，并通过本地读取验证。
- 私教知识库必须有来源、版本、引用、授权/复用状态、内容审核和安全边界；不得把未经授权的全文放入开源仓库。
- 当前见好工作区存在用户未提交修改。不得 stash、reset、clean、覆盖或顺手提交这些内容。必要时使用隔离工作树，完成后清理多余工作树。
- 使用 CodeGraph 优先定位见好代码；所有 shell 命令通过 rtk；不要读取或提交 DerivedData、构建产物、本地签名配置、设备日志和 .codegraph。
- 模拟器不能代替相机、签名、设备本地数据和真实写入的真机验证。真机不可用时要完成其余工作并准确记录阻塞，不能把模拟器通过写成完整完成。
- 每个里程碑结束后运行对应的 BeaconAgentKit、网关、PoC 和 iOS 测试；最终执行计划中的完整回归矩阵，并生成 /Users/zhanggengying/Documents/健身助手/docs/product_goal_beacon_agent_v0_2_report.md。
- 在最终完成前进行一次独立的正确性复查，优先检查隐私边界、越权写入、日期丢失、协议版本、断线恢复、幂等性、非流式回归和未覆盖失败路径。
- 可以在本地创建分支、工作树和提交，但未经我再次明确确认，不要 push、tag、发布软件包、部署服务或创建 Release。
- 不要因为任务规模大、耗时长或单个测试失败就提前结束目标。对可修复问题继续定位和修复；只有遇到确实需要我提供密码、设备、账号、授权或外部服务状态时才报告阻塞。
- 目标完成时必须列出两个仓库的最终分支和提交、所有测试结果、真机验证结果、剩余阻塞、未执行的外部操作，以及建议的推送/发布命令。

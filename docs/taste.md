# 口味系统设计(晨报个性化,v2)

2026-08-21 立项。起因:用户两刀砍中现行设计的死穴——
① 反馈区是 50 条 FIFO 流水账,不是记忆:老信号到上限就死,没有整合;
② 判例不带内容(`少看 | arXiv:2608.10475 | (无备注)`),评委面对哑谜,
   同一篇又因 seen 去重永不再现 ⇒ 无备注打分对未来选文效力≈0。

## 业界怎么做(调研 2026-08-21)

- **嵌入派**(Semantic Scholar Research Feeds / Scholar Inbox):论文向量
  (SPECTER2,引文图对比学习)+ 显式正负例(存进文件夹=正,标不相关=负),
  线性层排序。共同点:**每条反馈都天然携带论文内容**(向量),从不存哑谜。
- **LLM 画像派**(Radlinski/Ramos 可审读画像、POPI、LettinGo、MR.Rec、
  WWW'25 用户可控画像):把交互史蒸馏成**自然语言口味画像**,用户可读可改;
  事件账(journal)与画像(profile)分层,画像由 LLM 周期性整合更新。
  WWW'25 报告:让用户可控画像,效果最高 +50%。

选型:**画像派**。理由:单用户没有训练数据量;嵌入不可解释、违背"圣旨可读
可改"的现有文化;我们每天本来就有一次 opus 管线,顺路做整合零边际成本。

## 设计:两层记忆 + 内容化事件

```
事件层 journal(只增不删,永久)          画像层 profile(机器维护,恒短)
~/.pervio/papers/taste-journal.jsonl     memory.md「口味画像」节
一事一行,必带内容:                      ≤15 条可读规则,每条带证据:
{ts, act(👍/👎/多看/少看/讨论/开原文),   - 「纯 benchmark 无分析:零容忍」
 id, title, gist(一句话), hit(方向),       (证据 6 次,最近 08-20)
 note?}                                  - 「KV cache/推理效率:近期升温,
                                            上调」(证据 4 次,最近 08-19)
        └── 每天管线开头(score 之前)「整合」步 ──┘
            读:新事件 + 旧画像
            做:强化/衰减/合并/淘汰(信息靠提炼,不靠堆积)
            出:新画像(原子写回,条数恒定)
            败:沿用昨天的画像照常出刊,账本记一笔
            (2026-08-21 用户裁定:整合前置,画像永远当天新鲜,
             于是 score 无需再读原始判例——读单只剩两样)
```

- **journal 无上限**:一年几十 KB,是审计底账;评委不直接读全量。
- **画像恒短**:条数上限写死,每次整合必须"总结着长",老信号衰减进
  更抽象的规则里,而不是被挤掉——这就是「像 memory 一样维护」。
- **score 的读单**:圣旨(interests.md)+ 画像,就这两样。
  整合前置后画像当天新鲜,原始判例不再进评委的眼睛。
- **画像不许改圣旨**:行为与宣言冲突时,画像记录冲突并在刊物里点名,
  改圣旨的权力只在用户。

## 事件从哪来(采集升级)

1. **显式**:打分落账时自动反查标题+一句话(从当期档案),彻底消灭哑谜;
   长按菜单加"一句话原因"可选输入。
2. **界面**:读刊页每篇卡片上一键 👍/👎(现在埋在长按链接里,太深)。
3. **隐式(P3)**:对某篇开过「讨论」= 强兴趣;点开原文链接 = 弱兴趣。
   全部只落本地 journal,无遥测原则不变。

## 迁移

现有反馈区 50 条哑谜:一次性从历史刊物反查标题补全,转入 journal;
反馈区保留为"人在聊天里口述判例"的入口,写入同样进 journal。

## 明确不做

- 嵌入模型/协同过滤:单用户无数据量,不可解释,引入训练依赖。
- 云端画像:一切在用户 Mac,画像就是一段 markdown。

## 分期

- **P1 判例内容化**:feedback 落账带标题+gist;journal 落盘;score 读单换新。
- **P2 画像 + 整合步**:memory.md 画像节 + 管线开头整合 agent 步
  (opus,plan,失败不拦出刊)。
- **P3 采集升级**:卡片一键打分 UI + 讨论/开原文隐式信号。

参考:
- [Semantic Scholar Research Feed](https://www.semanticscholar.org/faq/research-feed-recommendations) ·
  [SPECTER](https://www.semanticscholar.org/paper/a3e4ceb42cbcd2c807d53aff90a8cb1f5ee3f031) ·
  [Scholar Inbox](https://arxiv.org/html/2504.08385v1)
- [User-Controllable Profiles (WWW'25)](https://dl.acm.org/doi/10.1145/3701716.3717734) ·
  [POPI](https://arxiv.org/pdf/2510.17881) ·
  [MR.Rec](https://arxiv.org/pdf/2510.14629) ·
  [LLM Agents for RecSys survey (EMNLP'25)](https://aclanthology.org/2025.findings-emnlp.620/)

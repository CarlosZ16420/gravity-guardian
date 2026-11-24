---
trigger: always_on
---

临时诊断文件按用户指定路径写入。未指定时避开 `.cache/`，即使旧对话用过，依次选项目约定的临时目录、已被 Git 忽略的 `artifacts/scratch/`、根目录 `scratch/`。临时文件不提交。

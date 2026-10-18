# mir→.sars链路打通验证（S1，复用sarust mir2sa）

用户否决JEV保守意见（暂不新建），要求直接打通。本节验证外部mir2sa直出.sars并用新sars编译。

## 环境
- cargo 1.99.1 / rustc 1.99.1（stable，rustup最小安装）
- mir2sa：/content/sa_all/sarust/rsc/mir2sa，cargo build成功（1 warning，spill.rs unused_mut）
- sars：zig-out/bin/sars 20M（zig 0.17.0 ReleaseSafe重建，含.sa+.sars双支持）

## 验证结果
| 输入 | mir2sa lower | sars check | 说明 |
|---|---|---|---|
| hi.mir.json → /tmp/hi.sars | wrote UNSUPPORTED=2 | check ok 47 instr | 与hi.sa有diff（新版lower多了num.sai import/spill reload/drop释放，属mir2sa版本演进） |
| corpus.mir.json → /tmp/corpus.sars | UNSUPPORTED=114 | UseAfterMove trap @f_match | Referee层语义问题，链路本身通 |
| real_driver.mir.json → /tmp/real_driver.sars | UNSUPPORTED=38 | PhiStateConflict trap @sum | 借用合并问题，链路本身通 |

- /tmp/hi.sars run：到extern broker边界（`sa run unsupported extern: core_fmt_rt_Argument...`，fmt externs需插件/broker，属预期）
- 结论：mir.json → .sars → sars check链路已打通；剩余trap是lower质量/Referee语义下一阶段工作，不阻塞建工程。

## 下一步（S2）
在sci-rust内新建rust/mir2sars工程（vendored复用mir2sa源码，注明来源与同步策略），默认输出.sars，cargo test + sars check双绿。

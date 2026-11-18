# 来源与范围

`Protocol.swift`、`Crypto.swift` 从本机 ZiVoice 独立验证工具复制并修改；原文件保留，未移动/删除。原探针作为冻结验证基线，不作为第二份生产协议维护位置。后续正式协议的唯一维护仓库为本仓库，ZiVoice仅使用版本固定的接口。

加密/帧参考 OpenBean，固定 c477586394a215b73d0119673e22095907fe865a，Apache-2.0，完整许可证见根目录 LICENSE.openbean。
https://github.com/imraywang/openbean/tree/c477586394a215b73d0119673e22095907fe865a

新增18/82 01启动、00停止的依据为该固定版本 docs/PROTOCOL.md §11（对方04.82实测）。这不是本设备04.92能力证明。取消/停止必须核对本次所有权及终态，不增加暂停、解绑、刷固件、历史列表/删除命令。

LiveOpus.swift改自原独立NativeOpus.swift：每帧48kHz/960样本，立即交付，不累计完整PCM。仅复用本机已有libopus 1.6.1，加载前校验SHA256：98dcd3cc62c6cf913b789051536ab246c56cc163c74bd8b4968ac467ec74b68b。未安装或打包该依赖。

AudioSink使用系统AVFAudio/CoreAudio和已安装BlackHole2ch，仅在显式传入UID时设置本进程输出；不把BlackHole作为最终发行依赖、不改默认输入或输出、不安装其副本。微信取音和正式驱动尚待实测。

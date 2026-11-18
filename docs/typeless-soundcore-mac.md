# 在 Mac 上用飞书版安克录音豆给 Typeless 收音

设备为中国大陆飞书版安克录音豆 D3200，设备显示的固件版本为 4.92.3.06。这台设备三击侧键后继续录音，没有进入 Typeless 官方指南描述的蓝灯配对状态。这个观察仅覆盖这台设备和该固件。

ZiBridge 把录音豆的声音送给 macOS 虚拟麦克风 BlackHole 2ch。已在这台 Mac 上用 ZiVoice 完成收音和听写。以下是给使用系统默认输入的 Typeless 的复现步骤，Typeless 端到端听写结果待验证。

1. 准备 ZiBridge 和 [BlackHole 2ch](https://existential.audio/blackhole/)。若使用源码构建，按[工作台分支的构建说明](../README.md)准备 Apple Silicon 构建环境。Typeless 需要 macOS 麦克风权限。
2. 确认录音豆空闲，暂时断开手机与录音豆的蓝牙连接，保留飞书绑定。将录音豆放到 Mac 附近。
3. 打开 ZiBridge，扫描并选择自己的设备。用途选「作为麦克风 · BlackHole 2ch」，点「开始收音」，等到显示正在收音。
4. 打开「系统设置 → 声音 → 输入」，选 **BlackHole 2ch**。记下先前的输入设备，输出继续使用原耳机或扬声器。对着录音豆说话，检查所选输入的电平是否变化。
5. 点击空白文本框，用 Typeless 平时的听写快捷键录一句测试文字。以文字实际出现作为听写通过标准。这个流程使用 Typeless 快捷键，设备双击启动 Typeless 尚未验证。
6. 用完先结束 Typeless 听写，再在 ZiBridge 点「结束」。等设备停止确认后断开连接，把系统输入切回原设备，即可让手机飞书重新连接。若提示停止未确认，请检查录音豆本体。设备可能保留普通录音并在重连手机后同步飞书。

## For the Typeless team

On one mainland China Feishu-edition soundcore recorder (D3200, firmware 4.92.3.06), three side-button presses continued recording instead of producing the flashing blue light described in the [official setup guide](https://www.typeless.com/help/devices/soundcore-work).

Our Mac app, ZiBridge (development repository: `372790111z-wq/ZiBridge`), sends live audio from the recorder to BlackHole 2ch. We verified the microphone route with ZiVoice. To reproduce with a Typeless client that follows the macOS default input:

1. Temporarily disconnect the recorder from the phone, keeping its Feishu binding. Connect it in ZiBridge, choose BlackHole 2ch microphone mode and start capture.
2. Under **System Settings → Sound → Input**, select **BlackHole 2ch**. Leave the output on the usual speakers or headphones. Speak into the recorder and check the input level.
3. Focus a text field and dictate with the Typeless keyboard shortcut. Text appearing in that field would confirm end-to-end compatibility. We have not independently verified this last step in Typeless.
4. Stop capture in ZiBridge, confirm the recorder has stopped, then disconnect and restore the previous system input.

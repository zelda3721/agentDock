# 应用图标说明

`app_icon.png` 当前是**占位图标**（216x216，脚本生成的深色背景 + 圆环/菱形几何图形），
仅用于保证工程可以正常编译与安装，**不是正式设计稿**。

## 现状

| 文件 | 尺寸 | 来源 | 状态 |
|---|---|---|---|
| app_icon.png | 216x216 | python3 脚本手写 PNG（zlib + struct）生成 | 占位，待替换 |

## 待办

// TODO(T0.9-01): 正式 UI 设计阶段替换为设计师产出的应用图标，
// 并按 HarmonyOS 规范补齐分层图标（layered image：background + foreground）与
// 深色模式资源目录（resources/dark/media）。

替换要求：

1. 保持文件名 `app_icon.png` 不变，否则需同步修改 `AppScope/app.json5` 中的 `"icon": "$media:app_icon"`。
2. 建议提供 HarmonyOS 分层图标（`layered_image`）以适配桌面图标的动效与形状裁剪。
3. 图标内容不得包含任何第三方商标或未授权素材。

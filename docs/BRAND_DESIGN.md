# Pocket Agent 视觉方向

## 已确认的范围与反馈

- 四个核心页面统一现代化：服务器列表、Codex 任务、SSH 终端、连接设置。
- 不必保留绿色；配色以美观和现代感为准。
- **明日方舟仅作为 App icon 参考，不是 UI 参考。**
- 大眼、腮红、玩偶感的猫/机器人/Q 版头像已被用户否定，不集成。
- 用户认可非 Q 版角色头像的画风，但要求进一步体现 Pocket Agent / Agent 身份。
- 不擅自转为徽章，不复制其他产品的品牌图形，不引入未来 Claude/pi 适配架构。

## 应用界面

当前可评估实现采用 Ink Navy / Periwinkle / Warm Ivory，尚待 Android 视觉验证，
不是用户已确认的最终配色。系统字体、明确标题与 metadata 层级、实底内容卡片、
深色终端；共享主题集中管理颜色、间距与圆角。

玻璃仅用于局部导航/浮层，正文和审批保持实底；高对比模式退化为实底。
Flutter 自绘材质不等同于原生 Apple Liquid Glass。
参考：[Apple — Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)。

必须验证 light/dark、大字体、窄屏、键盘展开、48dp 触控及对比度。
保留现有路由、功能和测试入口。评估通过前不宣称视觉升级已完成。

## App icon：原创角色头像

参考：[明日方舟官方 App icon](https://play.google.com/store/apps/details?id=com.YoStarEN.Arknights)。
仅借鉴角色头像式构图及绘画表现，不复制阿米娅或其他角色、阵营徽记、官方 logo。

- `mobile/assets/brand/portrait-study.png`：用户认可的画风基准；身份辨识尚不足。
- `mobile/assets/brand/agent-portrait-candidate.png`：保留角色与画风，加入轻量耳侧通信模块；
  尚待用户确认 Agent 身份表达，尚未替换平台 launcher icon。

图片通过内置 image_gen 生成/编辑，无 CLI/API fallback。原始输出保留于 Codex
generated_images，项目副本已保存于仓库。被否定的旧草案不复制进项目。

### 头像生成 prompt

```text
Use case: stylized-concept. Asset type: one square mobile APP ICON portrait concept for Pocket Agent. The user's reference is the CHARACTER-PORTRAIT APP ICON of Arknights, specifically its polished anime illustration and tightly cropped face, NOT its interface, faction emblems, logos or game HUD. Create a wholly original adult anime character: a composed young adult female engineer with a short ash-grey bob, a few loosely layered strands across the forehead, clear cool blue-grey eyes, and a very slight, natural closed-mouth smile. Her expression is attentive, intelligent and approachable, never vacant, exaggerated or babyish. Normal adult anime facial proportions, a defined jaw and visible neck; medium-small eyes with subtle iris highlights, NOT enormous doll eyes or chibi proportions. A simple dark jacket collar with a restrained cobalt lining is barely visible at the bottom. Style: premium hand-painted anime game key art adapted for an app icon, confident fine linework, carefully designed broad cel-shadow shapes combined with subtle painterly light, natural skin tones, cool reflected light in hair, sophisticated restrained saturation. Composition: close-cropped face and partial shoulders, slight three-quarter turn while looking toward viewer; face readable in the central circular safe area; strong dark/light silhouette. Full-bleed opaque slate-blue background with a quiet pale-grey light area behind the hair, no scenery. No rounded outer mask. No text, letters, badges, UI, command symbols, animal ears, headphones, robots, pocket props, childish smile, cheek blush circles, sparkles, glossy 3D, plush texture, emoji aesthetic or existing franchise characters. This is a carefully illustrated character avatar icon, not a mascot toy or sticker. Deliver one actual square image only.
```

### Agent 身份编辑 prompt

```text
Use case: precise-object-edit. Image 1 is the edit target: the user likes this portrait's face and mature anime illustration style for the Pocket Agent app icon, but it needs a clearer identity as a capable connected Agent. Change ONLY the visible ear area on the viewer's left: add one distinctive lightweight communication earpiece, elegantly fitted over the ear and partly tucked under the hair, with a short, fine microphone stem following the cheek contour but not reaching the mouth. The earpiece has a recognizable folded-pocket silhouette: a compact asymmetric rounded trapezoid, one folded upper lip, dark graphite housing, one restrained cobalt-blue edge and a tiny cool-blue status light. It is a sophisticated wearable companion link, not bulky gaming headphones, not a metal helmet. Make the design clear enough to read at app-icon size without dominating the face. Preserve exactly the same character identity, normal adult facial proportions, ash-grey hair, blue-grey eyes, small composed smile, head angle, collar, painterly linework, muted lighting and full-bleed opaque slate background. Do not add other props, UI overlays, text, letters, code symbols, chest badges, glow effects or decorative shapes. No chibi, blush dots, giant eyes, plastic 3D, animals or third-party logos. The result should feel like the same person now available as a calm, capable remote-working partner. One actual square app icon, no presentation board.
```

## 交付门槛

定稿后导出 Android/iOS 资产，检查 48px/64px、圆形/圆角蒙版、脸部安全区和背景不透明。
不能以大图效果替代真实 launcher 验证。没有 Mac/Xcode/真机环境，本轮不得宣称通过
iOS 构建、Icon Composer 分层效果或真机验证。

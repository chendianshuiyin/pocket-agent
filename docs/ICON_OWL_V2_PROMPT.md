# 无耳机头像 v2 生成记录

本图由内置 image_gen 生成，未使用 CLI/API fallback。参考输入是项目已有的
`mobile/assets/brand/portrait-study.png`，只作画风与构图参考。
此记录不表示用户已确认最终品牌设计。

输出原图原样复制为 `mobile/assets/brand/agent-portrait-owl-v2.png`。
1254 × 1254 RGB PNG，SHA-256：
`67afb98da7f5ebbad5a9d3f7f2a90a3d166350ba6acbebc40e1c8899b41ce2a3`。
生成时为预览探索；用户随后要求继续执行，现接入当前开发版 launcher。
标准尺寸导出不重绘源图，旧稿保留供追溯。

## 完整 prompt

```text
Use case: stylized-concept
Asset type: a single square illustrated App icon concept for Pocket Agent, a personal AI coding-agent companion that helps its owner manage work across remote servers. Preview exploration only.
Input image 1: the previously liked original portrait WITHOUT a headset; use it as a reference for quality, close-up composition and normal anime proportions, not as a character identity that must be copied exactly.
Primary request: redesign this portrait into an ORIGINAL quietly intelligent anime assistant character, using the serene, slightly deadpan, owl-inspired data-assistant sensibility of Ptilopsis (白面鸮) from Arknights as inspiration. The user disliked adding a headset and wants the character herself to communicate the agent identity. Do not reproduce Ptilopsis's exact face, hairstyle, costume, or game insignia.

Subject and expression: one adult female character with normal, elegant anime proportions, pale silver-white softly layered short hair, distinct feather-like locks subtly framing the temples, warm amber eyes, a composed and attentive gaze directed toward the owner, a very restrained friendly expression. Thoughtful and capable, with a gentle slightly synthetic intelligence to her presence; neither sultry nor cold or angry. A clean asymmetrical fringe, understated recognizable silhouette. Preserve the sophisticated non-chibi appeal of the reference.
Clothing: a simple graphite and ivory high-collar everyday technical jacket, clean panel shapes, only one subtle original clasp whose folded outline resembles a small pocket with a cursor-like notch. Keep this integrated and quiet; it must not dominate the face. The core of the icon is a memorable companion portrait, not a collection of technology props.
Style/medium: refined hand-painted 2D anime character illustration, clear fine linework, selective painterly shading, designed hair shapes rather than excessive individual photoreal strands, luminous but controlled amber irises. Strong tasteful character design suitable for a modern app. Less photoreal and less generic cinematic-game-render than the input.
Composition/framing: single centered head-and-upper-shoulders close-up, nearly front-facing with a subtle natural head turn, face fully readable, enough breathing room for hair and potential mobile icon masks, warm pale hair against a plain deep ink-blue/charcoal backdrop. Eyes and expression are the focal point. Fill the square canvas edge to edge with the artwork; no baked-in rounded border or icon bevel. Readable at small icon sizes.
Constraints: absolutely NO headset, headphones, earpiece, microphone, wires, goggles, robot face, visible circuit tattoos, cybernetic face seams, floating HUD, speech bubbles, code panels, terminal windows, added companion animal, weapons, giant decorative accessories, text, letters, watermark or existing brand/game logos. No chibi, baby face, giant round eyes, excessive blush, catgirl costume, glossy 3D mascot, or stock customer-service agent appearance. No contact sheet, no multiple variants in the canvas, no mockup phone, just one polished square icon illustration.
```

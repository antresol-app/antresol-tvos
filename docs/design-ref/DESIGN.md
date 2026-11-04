# Antresol design reference (extracted from the shipping web/iOS app, v0.3.0)

Screenshots: tv_*.png (1920x1080), phone_*.png (390x844) in this folder. Logo: logo-mark.svg
(glass "house/box" outline with white rounded play triangle), app-icon.svg, icon-192.png.
Splash: full-screen linear-gradient(160deg, #3a1c8c, #9b2fc9) with the mark + "Antresol" (700, 52px).

Overall: Apple-TV+-like. Pure black (#000) background, dark only. SF Pro (Display for titles,
Text for body, Rounded for numbers/avatars). Apple system colours.

Colours
- bg #000, bg-raised #121214, bg-elevated #1c1c1e, identity-bg #0b0b10
- label #f5f5f7, label-2 #ebebf5 @ 62–80%, label-3 #ebebf5 @ 36–60%, label-inverse #000
- accent / focus ring #0a84ff (pressed #0071e3); green #30d158, orange #ff9f0a, red #ff453a
- fills: #787880 @ 36% / 24%, #767680 @ 16% / 10%; hairline #ffffff1f
- glass: fill #1c1c20 @ 92% (or #282830 @ 60%) + 20px blur, border #ffffff14
- brand tile gradient #3a1c8c → #9b2fc9
- profile avatar gradients ("grad-1".."grad-8", 145deg):
  1 #5e5ce6→#bf5af2, 2 #0a84ff→#64d2ff, 3 #ff375f→#ff9f0a, 4 #30d158→#00c7be,
  5 #ff9f0a→#ffd60a, 6 #bf5af2→#ff375f, 7 #00c7be→#0a84ff, 8 #8e8e93→#48484a

Shape & motion
- radii: card 12, small card 10, control 12, sheet 20, pill 999; badges 6
- focus: scale 1.07 (cards lift 1.04) + soft shadow; ease-out cubic-bezier(.22,1,.36,1); 160/260/600ms

Layout patterns (see tv_.png, tv_movies.png)
- Top bar: logo mark + "Antresol" left; centred glass pill segmented nav
  [search icon | Home | Movies | TV Shows | Music | Books], selected item = white pill with black text;
  profile avatar circle (gradient + initial) right.
- Home hero: full-bleed backdrop (or artwork-colour tinted gradient when no backdrop) fading to black;
  eyebrow "NEW IN LIBRARY · MOVIE" (caps, small, semibold, label-2), huge bold title, year/meta line,
  buttons: white pill "▶ Play" (black text) + dark glass pill "ⓘ Details".
- Shelves: section title (bold ~24px) with chevron ">" link; horizontal rows of 2:3 poster cards
  (radius 12, title overlay when no poster), under-card title + year + badges ("1080p", "Audio EN RU").
- Grid pages: large bold page title left, segmented sort pill right ("Recently Added | By Title | By Year").
- Icons: 24-grid line icons, stroke 1.9, round caps (SF Symbols equivalents are fine on Apple platforms).
- Copy is localised EN + RU (server sends Accept-Language aware errors). Ship both.

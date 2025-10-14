# DESIGN_GUIDELINES.md
**Target:** macOS Tahoe (macOS 26), AppKit/SwiftUI hybrid OK  
**Layout:** Three-column (Sidebar → Content → Detail/Inspector)  
**Style:** Unified, glassy, keyboard-first, ultra-polished

---

## 0) TL;DR 
- **Liquid Glass** is the new system material across Apple platforms. Embrace translucency and depth but keep content legible first. :contentReference[oaicite:0]{index=0}  
- **Full-height sidebars** and **unified toolbars** remain core macOS patterns; they’re still trendy when used with restraint and clear hierarchy. :contentReference[oaicite:1]{index=1}  
- **Three-column navigation** is first-class with `NavigationSplitView` (SwiftUI) or `NSSplitViewController` (AppKit). :contentReference[oaicite:2]{index=2}  
- **SF Symbols 7** + symbol effects; use system icons before custom. :contentReference[oaicite:3]{index=3}  
- **System materials, system colors, and SF fonts** only; avoid hard-coded RGB, hand-rolled blur, or off-brand typography. :contentReference[oaicite:4]{index=4}

---

## 1) Product principles
- **Content > Chrome.** The UI should feel airy and quiet; the toolbar is powerful but never busy.
- **Keyboard-first.** Every primary action has a shortcut. Offer a Command Palette (⇧⌘P) and tie into Spotlight-style search patterns.
- **Opinionated defaults, progressive disclosure.** Show only task-critical actions; push the rest to menus/overflow.
- **Mac-native, not a web port.** Respect menu bar, toolbar, sidebar, sheets, and windowing behaviors.

---

## 2) Information architecture (three-column)
**Columns**
1) **Sidebar (Navigator):** Sources, sections, filters.  
2) **Content (Objects list/grid):** Results for the selection in the sidebar.  
3) **Detail/Inspector:** The focused item’s properties or editor.

**Column behavior**
- **Full-height sidebar** with translucent material; collapsible via ⌥⌘S and a toolbar toggle anchored at the far left. :contentReference[oaicite:5]{index=5}  
- **Resizable split bars**; persist widths per window using autosave (AppKit: `NSWindow.frameAutosaveName`, NSSplitView priorities). :contentReference[oaicite:6]{index=6}  
- **Breakpoints:**  
  - Narrow windows: auto-hide the inspector; detail overlays on demand.  
  - Very narrow: collapse to two columns; sidebar → popover if needed.
- **Empty/zero states:** Use `ContentUnavailableView` for blank content/detail with helpful actions. :contentReference[oaicite:7]{index=7}

---

## 3) Toolbar & titlebar (rich, but disciplined)
**Style**
- Prefer **Unified** (or **Unified Compact** for height-sensitive windows). Use **Expanded** only for document-centric apps that need a second bar. :contentReference[oaicite:8]{index=8}

**Item taxonomy & placement**
- **Leading edge (fixed):** Sidebar toggle, segmented view switcher (if global).  
- **Center (optional):** One **centered** item (e.g., scope picker) max.  
- **Trailing edge (fixed):** Inspector toggle (far right), Share, then **Search** (as `NSSearchToolbarItem`, which expands on focus). Keep these anchored so they don’t “chase” the user. :contentReference[oaicite:9]{index=9}

**Overflow & priority**
- Set visibility priorities so low-value items drop into the overflow first; never let Search or toggles vanish. (Use `NSToolbarItem` visibility priority + overflow.) :contentReference[oaicite:10]{index=10}

**Customization**
- Allow toolbar customization if your surface area is big; keep a sane default set.  
- Use **tracking separators** to visually align toolbar sections with split-view dividers. :contentReference[oaicite:11]{index=11}

**Accessory bars**
- Put contextual, per-selection tools in a **titlebar accessory** or an **accessory/bottom bar**; never overload the main toolbar. :contentReference[oaicite:12]{index=12}

---

## 4) Navigation & selection
- **Single selection drives the inspector**; multi-select swaps inspector to a batch-edit or summary mode.
- **Back/Forward** (⌘[ / ⌘]) navigate selection history within the content column.
- **Breadcrumbs** live in content header or accessory bar, not the toolbar.

---

## 5) Visual system (Tahoe / Liquid Glass)
**Materials**
- Use system **Liquid Glass** materials via AppKit/SwiftUI; don’t roll your own blur. Keep contrast high; content panes are opaque, navigational chrome can be translucent. :contentReference[oaicite:13]{index=13}  
- Respect **Reduce Transparency** and increased contrast. (Translucency must degrade gracefully to solid.) :contentReference[oaicite:14]{index=14}

**Color**
- Use **system colors** (label/secondaryLabel, separator, controlAccentColor). No hard-coded hex for text or chrome. Theme via the **accent color** only. :contentReference[oaicite:15]{index=15}

**Typography**
- Stick to **SF Pro** (variable). Use size/weight appropriate to role; don’t fake tracking. :contentReference[oaicite:16]{index=16}

**Iconography**
- Prefer **SF Symbols 7**; use filled/outlined pairs consistently and symbol effects sparingly for feedback. :contentReference[oaicite:17]{index=17}

**Motion**
- Keep animations subtle (hover reveals, content transitions, animated symbols). 120–200ms; no parallax circus.

---

## 6) Search & command
- Global search belongs in the toolbar as **`NSSearchToolbarItem`**; it expands on focus and collapses on blur. Support keyboard focus via ⌘F and ⇧⌘F for scoped search. :contentReference[oaicite:18]{index=18}
- Provide a **Command Palette** (⇧⌘P) with fuzzy actions; mirror the menu bar’s structure.
- Offer **type-ahead** search in lists; highlight matches and preserve scroll position.

---

## 7) Accessibility & internationalization
- **VoiceOver**: Name/role/state for all controls; logical focus order across columns.  
- **Contrast**: Meet WCAG 2.1 AA at a minimum; check translucency on busy wallpapers.  
- **Hit targets**: ≥ 28×28 px for toolbar controls (don’t miniaturize).  
- **Localization**: Leave room for 30–50% text expansion; avoid icon-only cryptograms unless universally understood.

---

## 8) Performance & stability
- **Materials are GPU-heavy.** Keep glass surfaces to navigation areas; avoid stacking overlapping blurs. Test on base M-series Macs. :contentReference[oaicite:19]{index=19}
- Avoid overdraw in content; prefer opaque views for lists/editors.
- Persist **window frame and split widths**; restore instantly on launch/open. :contentReference[oaicite:20]{index=20}

---

## 9) Engineering reference (quick picks)
- **Three-column:** SwiftUI `NavigationSplitView(sidebar:content:detail:)` with `.columnVisibility` and `navigationSplitViewColumnWidth()`. AppKit: `NSSplitViewController` with three items. :contentReference[oaicite:21]{index=21}  
- **Toolbar:** AppKit `NSToolbar` (Unified/Compact/Expanded), `NSSearchToolbarItem`, `NSSharingServicePickerToolbarItem`, `NSToolbarItemGroup`, `NSTrackingSeparatorToolbarItem`. :contentReference[oaicite:22]{index=22}  
- **Accessory:** `NSTitlebarAccessoryViewController` for secondary, context-specific controls. :contentReference[oaicite:23]{index=23}  
- **State restore:** `NSWindow.frameAutosaveName`; store split positions in user defaults if needed. :contentReference[oaicite:24]{index=24}

---

## 10) YC-level polish (what separates you from the herd)
- **Latency budget:** <100 ms for UI ops, <16 ms for scroll/drag frames. If you can’t hit it, simplify visuals.
- **First-run excellence:** Impeccable empty states, sample data, safe defaults, obvious next steps.
- **Micro-interactions:** Hover affordances, animated Symbols for success/failure, subtle spring on toggles.
- **Keyboard coverage:** 100% of primary flows are shortcut-reachable; show shortcuts in tooltips and menus.
- **Observability:** Built-in feedback (⌃⌘F), non-blocking crash recovery, and a debug panel for support.

---

## 11) Do / Don’t
**Do**
- Use system materials/colors/typography.  
- Keep toolbar minimal and anchored; collapse gracefully to overflow.  
- Make inspector toggle fixed on the trailing edge.

**Don’t**
- Hard-code colors, fonts, or blur effects.  
- Let core actions (Search, toggles) fall into overflow.  
- Ship without window/split width persistence.

---

## 12) QA checklist (ship gate)
- [ ] Sidebar/Inspector toggles work; columns remember widths per window.  
- [ ] Toolbar items prioritize correctly; Search expands/collapses cleanly.  
- [ ] Light/Dark/High-contrast/Reduce-transparency all pass legibility checks.  
- [ ] Keyboard: global search (⌘F), palette (⇧⌘P), column toggles, navigation.  
- [ ] Symbol set consistent; no raster PNGs for system icons.  
- [ ] Empty states are helpful; no dead ends.

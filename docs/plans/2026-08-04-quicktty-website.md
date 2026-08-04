# QuickTTY Website Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Создать и подготовить к публикации на `quicktty.app` англоязычный продуктовый сайт QuickTTY с future-proof переходом на latest stable, документацией и GitHub Pages deployment.

**Architecture:** Сайт — полностью статический набор HTML/CSS/JS в `site/`, без package manager, runtime framework и внешних шрифтов. GitHub Pages workflow публикует exact содержимое `site/`; стандартный Python validator проверяет локальные ссылки, обязательные metadata и ключевые product/release contracts и включается в `make lint`.

**Tech Stack:** Semantic HTML5, modern CSS, minimal vanilla JavaScript, Python 3 standard library, GitHub Pages Actions.

---

### Task 1: Зафиксировать brand assets и статический каркас

**Files:**
- Create: `site/assets/app-icon.png`
- Create: `site/CNAME`
- Create: `site/.nojekyll`
- Create: `site/robots.txt`
- Create: `site/sitemap.xml`

**Step 1: Добавить first-party icon**

Скопировать `QuickTTY/Assets.xcassets/AppIcon.appiconset/icon_512x512.png` в `site/assets/app-icon.png`. Не генерировать новый логотип и не подключать внешние assets.

**Step 2: Зафиксировать домен и crawler metadata**

`site/CNAME` содержит только `quicktty.app`. `robots.txt` разрешает indexing и указывает `https://quicktty.app/sitemap.xml`. Sitemap содержит `/`, `/docs/`, `/releases/` и `/privacy/`.

### Task 2: Реализовать главную страницу в terminal-editorial стиле

**Files:**
- Create: `site/index.html`
- Create: `site/assets/styles.css`
- Create: `site/assets/site.js`

**Step 1: Создать semantic page structure**

Главная содержит:

- skip link и sticky navigation `Product / Docs / Releases / GitHub / Download`;
- hero с copy `A native terminal workspace for macOS.`;
- primary CTA `Download latest stable` на `https://github.com/dntsk/quicktty/releases/latest`, без version-pinned DMG URL;
- compatibility line `macOS 15+ · Apple Silicon · Signed & notarized`;
- большой CSS-built product tableau с workspace selector, tabs, four split panes, broadcast/status details и Quake strip;
- sections для workspaces/splits, Quake mode, broadcast, search/shortcuts, coding-agent progress и Ghostty engine;
- final download CTA и footer.

Не заявлять QuickTTY как open source до появления first-party `LICENSE`; использовать `View source on GitHub`.

**Step 2: Реализовать визуальную систему**

Направление: industrial terminal editorial, не generic SaaS dashboard. Использовать graphite/ink background, cold cyan из app icon, restrained amber broadcast accent, editorial serif display + native monospace. Добавить subtle grid/noise, asymmetric composition и один orchestrated reveal. Не использовать purple gradients, external fonts, stock illustrations или card-grid из одинаковых rounded rectangles.

**Step 3: Добавить progressive enhancement**

`site.js` управляет mobile navigation, intersection reveals и текущим годом. Без JS весь контент и navigation остаются доступными. Учитывать `prefers-reduced-motion`.

### Task 3: Добавить документацию и supporting pages

**Files:**
- Create: `site/docs/index.html`
- Create: `site/releases/index.html`
- Create: `site/privacy/index.html`
- Modify: `QuickTTY/Resources/configuration-reference.md`

**Step 1: Создать Docs page**

Сделать desktop sidebar/mobile contents и разделы:

- Getting Started;
- Installation & Updates;
- Configuration;
- Keyboard Shortcuts;
- Tabs, Splits & Workspaces;
- Quake Mode;
- Broadcast Input;
- Search;
- Coding Agent Integrations;
- Troubleshooting.

Документировать exact config path, current shortcut grammar, stable/beta channel semantics и ссылки на full registry/agent integration source docs. Не копировать весь shortcut registry.

**Step 2: Создать Releases page**

Показать stable `0.1.2` build 9 как primary download и beta channel как opt-in superset stable. Ссылаться на immutable GitHub releases и full changelog. Не называть stable beta.

**Step 3: Создать Privacy page**

Только проверяемые утверждения: нет analytics/advertising SDK, update checks обращаются к GitHub feeds, terminal/network activity принадлежит запущенным пользователем процессам, agent hooks ставятся только вручную, local config/state paths. Не обещать невозможную сетевую изоляцию terminal processes.

**Step 4: Синхронизировать bundled config reference**

Уточнить `quicktty-update-channel = beta`: repository feed является надмножеством stable и предлагает самый новый stable или beta build; stable channel не получает prerelease.

### Task 4: Добавить site validation и deployment

**Files:**
- Create: `scripts/check-site.py`
- Modify: `Makefile`
- Create: `.github/workflows/pages.yml`

**Step 1: Написать failing validator**

Validator стандартной библиотекой Python рекурсивно читает `site/**/*.html` и проверяет:

- все local `href/src` существуют и не выходят из `site/`;
- у каждой страницы есть nonempty title, description, canonical, один `h1` и skip link;
- изображения имеют nonempty `alt`;
- нет `href="#"`, `TODO`, localhost URL или claim `open source`;
- CNAME равен `quicktty.app`;
- future-proof GitHub `releases/latest` URL, current version/build на Releases page и beta-superset copy присутствуют на соответствующих страницах;
- главная страница не содержит version-pinned DMG URL.

Run before implementation:

```sh
/usr/bin/python3 scripts/check-site.py
```

Expected: FAIL, пока site files отсутствуют или неполны.

**Step 2: Подключить validator**

Добавить `site-check` в `.PHONY` и dependency `lint`, не меняя release/signing targets.

Run:

```sh
make site-check
```

Expected: PASS.

**Step 3: Добавить GitHub Pages workflow**

Workflow запускается на push в `master` при изменениях `site/**` или самого workflow, поддерживает manual dispatch, использует official Pages actions, минимальные permissions, concurrency и публикует только `site/`. Никаких build dependencies или secrets не требуется.

### Task 5: Проверить production quality

**Files:**
- Review: все `site/**`, workflow, validator и Makefile diff

**Step 1: Выполнить focused checks**

Run:

```sh
make site-check
make lint
git diff --check
```

Expected: PASS. Не запускать release/signing и не менять `docs/appcasts/beta.xml`.

**Step 2: Выполнить local HTTP smoke**

Run:

```sh
/usr/bin/python3 -m http.server 4173 --directory site
```

Проверить HTTP 200 для `/`, `/docs/`, `/releases/`, `/privacy/`, CSS, JS и icon. Остановить server после проверки.

**Step 3: Выполнить responsive/accessibility review**

Проверить desktop/mobile layout, keyboard focus, reduced motion, contrast, no-JS navigation и отсутствие horizontal overflow. Ничего не коммитить и не публиковать без отдельного явного запроса пользователя.

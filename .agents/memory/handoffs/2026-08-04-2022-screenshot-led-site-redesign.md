# Handoff: screenshot-led редизайн главной страницы сайта

- **Дата:** 2026-08-04
- **Ветка:** master
- **Статус дерева:** clean после evidence commit

## Выполнено

- Главная `site/index.html` перестроена вокруг реальных скриншотов workspace, Quake и broadcast.
- Fake CSS terminal и связанный декоративный UI удалены из `site/assets/styles.css`.
- Добавлены light/dark homepage-секции, адаптивное кадрирование скриншотов, контрастный focus и mobile navigation overrides.
- После quality review исправлены селекторы `.js .home-page` для mobile menu и восстановлен flex-layout CTA. После public feedback fixed-height screenshot crops удалены: все изображения сохраняют intrinsic aspect ratio.
- Docs, Releases и Privacy переведены на общий `.content-page`: та же светлая native macOS typography, header, mobile menu, buttons и footer; page-specific docs/release/privacy layouts адаптированы без изменения содержания.
- `site/assets/site.js` не изменялся.
- Screenshot-led главная опубликована commit `a5e43dc`; последующие visual fixes и единая secondary-page system публикуются отдельными commits.

## Проверки

- Spec review — PASS.
- Code-quality re-review главной — APPROVED.
- Quality review secondary pages — APPROVED.
- `make site-check` — PASS, 4 HTML pages.
- `git diff --check` — PASS.
- Local HTTP smoke — PASS для `/`, `/docs/`, `/releases/`, `/privacy/`, CSS, JS и трёх screenshot assets; secondary pages подтверждены с `body.content-page`.
- Public verification — PASS: четыре страницы отвечают HTTP 200; `workspace.png`, `broadcast.png`, `quake.png` совпадают с repository files по SHA-256.

## Незавершённое

- В окружении нет headless-браузера, поэтому optional browser visual smoke не выполнен; automated и public checks завершены.

## Следующий шаг

1. Обязательных действий нет. При необходимости отдельно выполнить manual visual smoke на 1440, 760 и 320 px.

## Важный контекст

- Главная CTA использует только `https://github.com/dntsk/quicktty/releases/latest`.
- Текст не заявляет open-source статус; используется формулировка `View source on GitHub`.
- На всех ширинах screenshots масштабируются пропорционально исходному размеру без crop, фиксированной высоты и horizontal overflow.

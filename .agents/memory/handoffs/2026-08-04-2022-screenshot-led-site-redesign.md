# Handoff: screenshot-led редизайн главной страницы сайта

- **Дата:** 2026-08-04
- **Ветка:** master
- **Статус дерева:** есть незакоммиченные изменения

## Выполнено

- Главная `site/index.html` перестроена вокруг реальных скриншотов workspace, Quake и broadcast.
- Fake CSS terminal и связанный декоративный UI удалены из `site/assets/styles.css`.
- Добавлены light/dark homepage-секции, адаптивное кадрирование скриншотов, контрастный focus и mobile navigation overrides.
- После quality review исправлены селекторы `.js .home-page` для mobile menu, восстановлен flex-layout CTA и включены работающие `object-fit`/`object-position` screenshot crops.
- Docs, Releases, Privacy и `site/assets/site.js` не изменялись.

## Проверки

- Spec review — PASS.
- Code-quality re-review — APPROVED.
- `make site-check` — PASS, 4 HTML pages.
- `git diff --check` — PASS.
- Local HTTP smoke — PASS для `/`, `/docs/`, `/releases/`, `/privacy/`, CSS, JS и трёх screenshot assets.

## Незавершённое

- В окружении нет headless-браузера, поэтому browser visual smoke не выполнен.
- Три предоставленных файла в `site/assets/screenshots/` остаются untracked; их содержимое не изменялось.

## Следующий шаг

1. Просмотреть `/` вручную при ширинах 1440, 760 и 320 px, затем добавить site-файлы и предоставленные скриншоты в следующий пользовательский commit.

## Важный контекст

- Главная CTA использует только `https://github.com/dntsk/quicktty/releases/latest`.
- Текст не заявляет open-source статус; используется формулировка `View source on GitHub`.
- На ширине до 560 px screenshot-контейнеры кадрируют изображения, сохраняя читаемый масштаб и не создавая overflow страницы.

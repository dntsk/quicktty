# Handoff: самодостаточная документация сайта

- **Дата:** 2026-08-04
- **Ветка:** master
- **Статус дерева:** clean после publication commit

## Выполнено

- В `site/docs/index.html` добавлены самодостаточные правила настройки сочетаний и полное руководство по интеграциям Pi, Claude Code и Codex.
- Существующие полные таблицы сочетаний сохранены; Quake Mode явно описывает `Cmd+Opt+P` для Normal ↔ Quake и отдельный `F12` для show/hide.
- В `scripts/check-site.py` добавлены exact shortcut-map comparison, exact bundled JSON comparison, полный agent/helper contract check и запрет ссылок Docs на repository Markdown, включая `www.github.com`.
- `site/assets/styles.css` уже содержал незакоммиченные стили таблиц; дополнительных правок не потребовалось.

## Проверки

- `python3 -m py_compile scripts/check-site.py` — PASS.
- `make site-check` — PASS, 4 HTML-страницы.
- `git diff --check` — PASS.
- Негативные smoke-проверки wrong chord и wrong nil default — PASS.
- Встроенные JSON сверены с bundled examples — точное совпадение.
- Final spec/quality re-review — APPROVED.

## Незавершённое

- Нет.

## Следующий шаг

1. Обязательных действий нет.

## Важный контекст

- Полные таблицы сочетаний и их стили опубликованы вместе с self-contained agent guide.

# Visual Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Запустить один видимый контейнер с живой терминальной surface, config-driven normal/Quake presentation и Quake hotkey.

**Architecture:** `WindowCoordinator` будет владеть `NormalWindowController`, `QuakeWindowController` и `PresentationController`, который перепривязывает один `WorkspaceViewController`. `AppDelegate` создаёт config после Ghostty bridge, применяет активную config к coordinator и удерживает watcher/hotkey без доступа hosted tests к production-файлам.

**Tech Stack:** Swift 6, AppKit, Carbon, XcodeGen, Swift Testing.

---

### Task 1: Презентация и chrome

**Files:**
- Modify: `GhostTerm/WindowCoordinator.swift`
- Modify: `GhostTerm/Presentation/PresentationController.swift`
- Modify: `GhostTerm/Presentation/QuakeWindowController.swift`
- Modify: `GhostTerm/Presentation/WorkspaceViewController.swift`

**Step 1:** Заменить legacy normal container на `NormalWindowController` и reparent workspace через `PresentationController`.

**Step 2:** Сохранить normal frame, sheets и close confirmation через текущий normal window.

**Step 3:** Перенести workspace selector вправо, оставив tab bar гибким слева.

### Task 2: Config и hotkey

**Files:**
- Create: `GhostTerm/Input/GlobalHotKeyController.swift`
- Modify: `GhostTerm/AppDelegate.swift`
- Modify: `GhostTerm/Presentation/PresentationController.swift`
- Modify: `project.yml`

**Step 1:** Добавить Carbon register/unregister для одного hotkey и pure conversion API.

**Step 2:** Создать/запустить `ConfigController` после bridge, применяя presentation и hotkey без перезапуска surface.

**Step 3:** Добавить command меню для переключения режима, сохраняя config только после успешного transition.

### Task 3: Tests and verification

**Files:**
- Create: `GhostTermTests/Input/HotKeyDescriptorCarbonTests.swift`
- Modify: `GhostTermTests/Presentation/PresentationStateMachineTests.swift`

**Step 1:** Проверить Carbon conversion без регистрации.

**Step 2:** Проверить config-driven transition без persistence callback.

**Step 3:** Сгенерировать проект, отформатировать, запустить targeted tests и build.

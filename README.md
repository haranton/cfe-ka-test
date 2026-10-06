# CI расширения на Vanessa Runner

GitHub Actions напрямую запускает команды Vanessa Runner. Все параметры 1С находятся в штатном файле autumn-properties.json.

## Конфиг

Укажите в autumn-properties.json:

- vrunner.ibconnection — существующую тестовую базу: /FC:\1C\Test либо /Sserver\database.
- vrunner.v8version — установленную версию платформы.
- vrunner.extension-name — имя расширения.
- vrunner.cfe.load.src — папку XML-исходников или готовый CFE.
- vrunner.cfe.unload.out — путь к собранному CFE.

Подключение пока пустое: перед запуском укажите свою постоянную тестовую базу. Пароль хранится в Actions Secret ONEC_DB_PASSWORD, имя пользователя — в ONEC_DB_USER. Локально используйте переменные VRUNNER_DBPWD и VRUNNER_DBUSER.

При переносе проекта меняйте этот JSON. Если адрес базы должен оставаться только в настройках GitHub, задайте Actions Variable ONEC_TEST_CONNECTION: переменная VRUNNER_IBCONNECTION имеет приоритет над JSON.

## Команды

Запускайте из корня проекта после заполнения подключения:

```powershell
# Загрузить расширение и обновить его в тестовой базе.
vrunner cfe load

# Выгрузить установленное расширение в build/extension.cfe.
vrunner cfe unload

```

Vanessa Runner сам читает autumn-properties.json. CI выполняет загрузку и выгрузку расширения.

CI использует постоянную базу: данные сохраняются, расширение обновляется при каждом прогоне. Создание временных баз и загрузка основной конфигурации из CF не выполняются.

При загрузке XML платформа обновляет ConfigDumpInfo.xml в рабочем каталоге runner. Workflow не коммитит и не отправляет эти служебные изменения в Git.

## GitHub Actions

В .github/workflows/build-cfe.yml остаются две команды vrunner и шаги GitHub: получение коммита, сохранение CFE, создание PR после успеха. Отдельного build.ps1 нет. Несколько строк PowerShell проверяют заполнение подключения и создают каталог для выходного файла.

Сборки всех веток выполняются последовательно. Вывод команд и ошибки видны в шагах Actions. Готовый CFE хранится 14 дней. При ошибке нового PR не будет; проверка существующего PR станет красной.

Слияние в main выполняет владелец после ревью, успешного build_1c и одобрения. Ветка должна включать актуальный main. Новые коммиты снимают прежнее одобрение.

## Перенос

Подключите Windows runner к новому репозиторию, установите 1С, OneScript и Vanessa Runner, измените autumn-properties.json и Secrets. В GitHub разрешите Actions создавать PR и настройте защиту main с проверкой build_1c и одним одобрением.

ITSM-агент отправляет ветки в этот репозиторий. Если агент работает в другом GitHub workflow, используйте GitHub App token или PAT: push через встроенный GITHUB_TOKEN не запускает следующий workflow.

На текущем компьютере runner запускается после перезагрузки командой:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ci\start-runner.ps1

```

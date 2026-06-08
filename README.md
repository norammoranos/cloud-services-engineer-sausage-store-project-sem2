# Сосисочная — финальный проект второго семестра

Репозиторий содержит сборку и деплой учебного интернет-магазина "Сосисочная" в Kubernetes. В состав входят:

- `backend` на Spring Boot с PostgreSQL, MongoDB, Flyway и Vault;
- `backend-report` на Go с MongoDB;
- `frontend` на Angular и nginx;
- Helm chart с subcharts `backend`, `backend-report`, `frontend`, `infra`;
- GitHub Actions pipeline для публикации Docker images, загрузки Helm chart в Nexus и деплоя в Kubernetes.

## Параметры деплоя

| Параметр | Значение |
| -------- | -------- |
| Kubernetes namespace | `r-devops-magistracy-project-2sem-1003690211` |
| Helm release | `sausage-store` |
| Ingress host | `front-norammoranos.2sem.students-projects.ru` |
| Docker images | `noranori/sausage-backend`, `noranori/sausage-frontend`, `noranori/sausage-backend-report` |
| TLS secret | `2sem-students-projects-wildcard-secret` |

## Структура

```text
backend/              # Java Spring Boot, PostgreSQL, MongoDB, Flyway
backend-report/       # Go report service, MongoDB, /api/v1/health
frontend/             # Angular frontend, nginx runtime
sausage-store-chart/  # Helm chart: backend, backend-report, frontend, infra
.github/workflows/    # GitHub Actions pipeline
```

## GitHub Secrets

Перед запуском pipeline в `Settings -> Secrets and variables -> Actions` должны быть заданы:

```text
DOCKER_USER
DOCKER_PASSWORD
NEXUS_HELM_REPO
NEXUS_HELM_REPO_USER
NEXUS_HELM_REPO_PASSWORD
KUBE_CONFIG
VAULT_HOST
VAULT_TOKEN
```

Назначение secrets:

| Secret | Назначение |
| ------ | ---------- |
| `DOCKER_USER` / `DOCKER_PASSWORD` | логин и access token Docker Hub |
| `NEXUS_HELM_REPO` | URL hosted Helm repository в Nexus |
| `NEXUS_HELM_REPO_USER` / `NEXUS_HELM_REPO_PASSWORD` | доступ к Nexus repository |
| `KUBE_CONFIG` | kubeconfig для целевого namespace |
| `VAULT_HOST` / `VAULT_TOKEN` | доступ backend к Vault |

`NEXUS_HELM_REPO` указывает на hosted Helm repository:

```text
https://nexus.cloud-services-engineer.education-services.ru/repository/<repository-name>
```

`KUBE_CONFIG` может содержать чистый kubeconfig YAML или файл тренажера с текстом перед `apiVersion:`.
Workflow извлекает YAML-часть перед `helm upgrade`.

`VAULT_HOST` задается без протокола. `VAULT_TOKEN` должен иметь доступ на чтение secret path приложения.

## Vault для backend

Backend использует вариант повышенной сложности: параметры подключения к БД для Spring-приложения не передаются через Helm values. Они читаются из Vault path:

```text
kv/sausage-store
```

Ключи:

```text
spring.datasource.username
spring.datasource.password
spring.data.mongodb.uri
```

Helm chart передает backend только параметры подключения к Vault:

```text
SPRING_CLOUD_VAULT_TOKEN
SPRING_CLOUD_VAULT_HOST
SPRING_CLOUD_VAULT_SCHEME
SPRING_CLOUD_VAULT_PORT
```

Перед деплоем Vault должен быть доступен по `VAULT_HOST`, unsealed и содержать эти ключи.

## Перед запуском pipeline

- Docker Hub access token должен иметь право push в repositories `noranori/sausage-backend`, `noranori/sausage-frontend`, `noranori/sausage-backend-report`.
- Docker images должны быть доступны кластеру без `imagePullSecrets`, поэтому repositories должны быть публичными либо кластер должен иметь отдельную настройку доступа к registry.
- Nexus repository должен быть типа `helm(hosted)` с `Deployment policy: Allow redeploy`.
- Vault должен отвечать снаружи на порт `8200`; backend получает схему `http` и порт `8200` из default values.
- Kubeconfig должен давать доступ к namespace `r-devops-magistracy-project-2sem-1003690211`.

## Локальные проверки

Если локально нет `helm`, `kubectl`, `go` или `mvn`, проверки можно выполнять контейнерами.

```bash
docker build -t sausage-backend:test --build-arg VERSION=test ./backend
docker build -t sausage-frontend:test ./frontend
docker build -t sausage-backend-report:test ./backend-report
```

```bash
docker run --rm -v "$PWD:/work" -w /work alpine/helm:3.14.4 \
  lint sausage-store-chart \
  --set global.vault.host=vault.example.local \
  --set global.vault.vaultToken=dummy-token
docker run --rm -v "$PWD:/work" -v /tmp:/tmp -w /work alpine/helm:3.14.4 \
  template sausage-store sausage-store-chart \
  --namespace r-devops-magistracy-project-2sem-1003690211 \
  --set global.vault.host=vault.example.local \
  --set global.vault.vaultToken=dummy-token \
  --output-dir /tmp/final-helm-rendered
```

```bash
awk 'found || /^apiVersion:/{found=1; print}' ../config > /tmp/final-kubeconfig
chmod 600 /tmp/final-kubeconfig
docker run --rm --user 0 \
  -v /tmp/final-kubeconfig:/kubeconfig:ro \
  -v /tmp/final-helm-rendered:/rendered:ro \
  bitnami/kubectl:latest \
  --kubeconfig /kubeconfig \
  apply --dry-run=server --recursive -f /rendered \
  -n r-devops-magistracy-project-2sem-1003690211
```

## Pipeline

Pipeline запускается на `push` в `main` и вручную через `workflow_dispatch`.

Jobs:

1. `preflight` — проверяет, что все обязательные GitHub Secrets заданы.
2. `build_and_push_to_docker_hub` — собирает и публикует три Docker image.
3. `add_helm_chart_to_nexus` — lint/package chart и upload `.tgz` в Nexus.
4. `deploy_helm_chart_to_kubernetes` — добавляет Nexus Helm repo, выполняет `helm upgrade --install` и запускает post-deploy smoke tests.

## Acceptance checks

Pipeline запускает smoke tests автоматически в конце deploy job:

```text
scripts/acceptance-check.sh
```

Этот же скрипт можно запустить локально после deploy:

```bash
scripts/acceptance-check.sh
```

Скрипт проверяет Helm release, `kubectl get po`, `kubectl get ing`, rollout workload'ов,
`mongodb-init`, `describe vpa`, `describe hpa`, VPA/HPA conditions, Ingress, список товаров,
оформление тестового заказа, recent logs без `fatal/panic/exception/error` и health `backend-report`.
Он не печатает kubeconfig secrets. По умолчанию скрипт создает один тестовый заказ;
чтобы пропустить POST `/api/orders`, используйте:

```bash
CREATE_TEST_ORDER=0 scripts/acceptance-check.sh
```

Базовые ручные команды:

```bash
helm --kubeconfig /tmp/final-kubeconfig list \
  -n r-devops-magistracy-project-2sem-1003690211

docker run --rm --user 0 \
  -v /tmp/final-kubeconfig:/kubeconfig:ro \
  bitnami/kubectl:latest \
  --kubeconfig /kubeconfig \
  get pods,deployments,statefulsets,services,ingress,hpa,vpa,jobs \
  -n r-devops-magistracy-project-2sem-1003690211
```

Ожидаемый результат:

- `helm list` показывает release `sausage-store` со статусом `deployed`;
- `postgresql`, `mongodb`, `backend`, `backend-report`, `frontend` работают;
- `mongodb-init` завершен со статусом `Completed`;
- Ingress `front-norammoranos.2sem.students-projects.ru` открывает frontend;
- список товаров, корзина и оформление заказа работают;
- backend liveness `/actuator/health` отвечает `UP`;
- backend-report `/api/v1/health` отвечает `200`;
- VPA для backend имеет `RecommendationProvided`;
- HPA для backend-report имеет `ScalingActive=True`.

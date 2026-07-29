# Guía Práctica — Examen Final CI/CD

## Estructura del examen

```
70 pts — Bloque A: Construcción y Despliegue (Parte I)
25 pts   → Pipeline base (Docker + CI/CD + K8s rolling update)
25 pts   → Segunda estrategia de despliegue (Canary o Blue-Green)
20 pts   → Componentes adicionales (2 de 3)

30 pts — Bloque B: Pruebas e Informe (Parte II)
10 pts   → Justificación de estrategia elegida
10 pts   → Métricas DORA (lead time, frecuencia, change failure rate)
10 pts   → README + documento de reflexión
```

---

## PARTE I — Construcción y Despliegue

### Paso 1: Verificar app en local

```bash
cd inventario-app
npm install
npm test          # 5 tests deben pasar (node:test)
npm start         # servidor en http://localhost:3000
curl localhost:3000/health       # → {"status":"ok"}
curl localhost:3000/version      # → {"version":"v1","color":"blue",...}
curl localhost:3000/api/products # → lista de 3 productos seed
```

⚠️ **Problema común:** `data/products.json` no existe → `db.js` lo crea automaticamente con el seed. Si hay errores de permisos, revisa que `data/` exista y sea escribible.

---

### Paso 2: Dockerfile multi-stage

El `Dockerfile` ya está escrito y tiene dos etapas:

| Etapa | Base | Qué hace |
|-------|------|----------|
| `builder` | `node:18-alpine` | `npm ci` + `npm test` (build **falla** si tests fallan) |
| `runtime` | `node:18-alpine` | Copia solo `node_modules/`, `public/`, `db.js`, `server.js`, `data/` |

```bash
docker build -t inventario-app ./inventario-app
docker run -d -p 3000:3000 --name inventario inventario-app

# Probar endpoints
curl localhost:3000/health
curl localhost:3000/version
curl localhost:3000/api/products
curl -X POST localhost:3000/api/products -H "Content-Type: application/json" \
  -d '{"name":"Laptop","sku":"LAP-001","stock":10,"price":899.99}'

docker stop inventario && docker rm inventario
```

**⚠️ Posibles cambios del profesor:**
- Podría pedir que el test incluya `lint` adicional
- Podría cambiar la versión de Node (`node:20-alpine`)
- Podría solicitar un `.dockerignore` explícito (agregar `node_modules/`, `.git`, `data/*.json`)

---

### Paso 3: GitHub + CI/CD

**Crear repo público** en GitHub: `inventario-app`

```bash
cd practica-examen
git init
git add .
git commit -m "Initial commit: inventario-app con Dockerfile, CI/CD y K8s"
git branch -M main
git remote add origin https://github.com/TU_USUARIO/inventario-app.git
git push -u origin main
```

**Estructura del repo:**
```
├── inventario-app/          # Código fuente
│   ├── Dockerfile
│   ├── server.js / db.js / server.test.js
│   ├── package.json
│   ├── public/
│   └── .gitignore
├── .github/workflows/ci-cd.yml
└── k8s/
    ├── deployment.yaml
    ├── service.yaml
    ├── deployment-config.yaml
    ├── canary/
    │   ├── stable.yaml
    │   ├── new.yaml
    │   └── service.yaml
    └── blue-green/      # (si eliges esta estrategia)
```

**Pipeline (`ci-cd.yml`):** dos jobs encadenados (`build-test` → `build-push`).
- `build-test`: `npm ci` + `npm test` en Node 18
- `build-push`: build + push a `ghcr.io` con tag `sha-xxx` y `latest`

Además incluye escaneo Trivy (severidad CRITICAL → fail).

**⚠️ Posibles cambios:**
- Podrían pedir usar `Docker Hub` en vez de `ghcr.io` — cambiar `REGISTRY` y login
- Podrían pedir tags semánticos (`v1.0.0`, `v2.0.0`) además de `latest` y `sha`
- Podrían pedir que el pipeline haga `deploy` automático a Minikube vía `kubectl` (necesitarías un self-hosted runner o `kubectl` action)

**Después del push:**
1. Ve a **Actions** en GitHub
2. Confirma ambos jobs en verde
3. Verifica la imagen en `ghcr.io/TU_USUARIO/inventario-app:latest`

---

### Paso 4: Kubernetes base (RollingUpdate)

**Iniciar Minikube:**
```bash
minikube start --driver=docker
```

**⚠️ Importante:** Antes de aplicar, edita todos los `k8s/*.yaml` y cambia `TU_USUARIO` por tu usuario real de GitHub. La imagen debe ser `ghcr.io/TU_USUARIO/inventario-app:latest`.

```bash
kubectl apply -f k8s/deployment-config.yaml  # ConfigMap
kubectl apply -f k8s/service.yaml            # Service ClusterIP
kubectl apply -f k8s/deployment.yaml         # Deployment 2 réplicas

kubectl rollout status deployment/inventario-app
kubectl get pods
kubectl get service inventario-app
```

**Probar:**
```bash
minikube service inventario-app --url
curl $(minikube service inventario-app --url)/health
curl $(minikube service inventario-app --url)/version
curl $(minikube service inventario-app --url)/api/products
```

**Detalles del `deployment.yaml`:**
| Campo | Valor | Propósito |
|-------|-------|-----------|
| `replicas` | 2 | Mínimo 2 réplicas |
| `strategy.type` | `RollingUpdate` | Actualización gradual |
| `maxUnavailable` | 1 | Máximo 1 pod fuera |
| `maxSurge` | 1 | Máximo 1 pod extra |
| `readinessProbe` | `/health`, delay 5s, period 10s, threshold 6 | Sabe cuándo está listo |
| `livenessProbe` | `/health`, delay 15s, period 20s | Detecta pods colgados |
| `secretKeyRef` | `API_KEY` desde `inventario-app-secrets` | Secretos |

---

### Paso 5: Persistencia de datos (para el informe)

```bash
# Crear producto
curl -X POST $(minikube service inventario-app --url)/api/products \
  -H "Content-Type: application/json" \
  -d '{"name":"Producto nuevo","sku":"NEW-001","stock":5,"price":99.99}'

# Forzar eliminación de un pod
kubectl delete pod -l app=inventario-app --field-selector status.phase=Running --limit=1
kubectl get pods --watch   # esperar a que el nuevo esté listo

# Verificar: el producto desapareció
curl -s $(minikube service inventario-app --url)/api/products | jq '. | length'
```

**Para el informe:** La base de datos es un archivo JSON local (`data/products.json`) dentro del pod. Al recrearse el pod, se usa la imagen original que contiene solo los 3 productos seed. No hay volumen persistente → los datos se pierden. Esto NO es un error, es el comportamiento esperado de una DB local sin PVC.

---

### Paso 6: Elegir estrategia (Canary o Blue-Green)

| Estrategia | Cómo funciona en K8s | Ventaja |
|------------|---------------------|---------|
| **Canary** | 2 Deployments con distinta cantidad de réplicas (ej: 4 stable + 1 canary). El Service balancea proporcionalmente | No duplica infraestructura, tráfico gradual |
| **Blue-Green** | 2 Deployments independientes con distinta versión. El Service apunta a uno u otro cambiando el selector | Corte instantáneo, rollback inmediato |

**Justificación para el informe:** El repositorio actual usa **Canary** porque:
- Los Services de K8s distribuyen tráfico proporcional a la cantidad de pods que matchean el selector
- Con 4 pods stable (v1/blue) + 1 pod canary (v2/green) → ~80% / ~20%
- Permite probar cambios en producción con riesgo mínimo
- No requiere duplicar infraestructura como Blue-Green

**⚠️ Si el profesor pide Blue-Green en vez de Canary:** crear carpeta `k8s/blue-green/` con:
- `blue.yaml` (Deployment v1, label `version: blue`)
- `green.yaml` (Deployment v2, label `version: green`)
- `service.yaml` sin selector fijo; para cambiar tráfico: `kubectl patch service inventario-app -p '{"spec":{"selector":{"version":"green"}}}'`

---

### Paso 7: Implementar Canary

Edita `k8s/canary/stable.yaml` y `k8s/canary/new.yaml`: cambia `TU_USUARIO`.

```bash
kubectl apply -f k8s/canary/stable.yaml   # 4 pods v1 (blue)
kubectl apply -f k8s/canary/new.yaml      # 1 pod v2 (green)
kubectl apply -f k8s/canary/service.yaml  # Service balancea entre ambos

kubectl get pods  # 4 con -stable, 1 con -canary
```

**Probar distribución de tráfico:**
```bash
for i in $(seq 1 20); do
  curl -s $(minikube service inventario-app --url)/version | jq -r '.color + " (v" + .version + ")"'
done
```
Esperado: ~4 respuestas "green (v2)" y ~16 "blue (v1)".

**⚠️ Si el Service del paso 4 ya existe,** el Service canary tiene el mismo nombre (`inventario-app`) y lo reemplazará. Si quieres mantener ambos, usa distinto nombre (ej: `inventario-app-canary`).

---

### Paso 8: Componentes adicionales (elige al menos 2)

#### Componente 1: Manejo de Secretos

El `deployment.yaml` ya incluye `secretKeyRef` para `API_KEY`. Solo falta crear el Secret:

```bash
kubectl create secret generic inventario-app-secrets \
  --from-literal=API_KEY="sk-test-1234567890"
```

**Verificar:**
```bash
kubectl get deployment inventario-app -o yaml | grep -A5 secretKeyRef
kubectl exec -it $(kubectl get pod -l app=inventario-app -o jsonpath='{.items[0].metadata.name}') -- env | grep API_KEY
```

**⚠️ Posibles cambios del profesor:**
- Podría pedir que el Secret se cree desde un YAML (versionado) en vez de CLI (ver `GUIA_SECRETS.md` en la práctica de transformación)
- Podría pedir múltiples secretos (`DB_PASSWORD`, `JWT_SECRET`, etc.)

#### Componente 2: Escaneo de seguridad con Trivy

Ya incluido en `ci-cd.yml`. Escanea después del push y falla si hay CRITICAL.

```bash
# Prueba local:
docker run --rm aquasecurity/trivy:latest image --severity CRITICAL inventario-app
```

**⚠️ Posibles cambios:**
- Podrían pedir HIGH además de CRITICAL
- Podrían pedir que el escaneo sea un job separado (no un paso dentro de `build-push`)
- Podrían pedir generación de reporte SARIF y subirlo como artifact

#### Componente 3: Readiness con arranque lento

La app ya soporta `STARTUP_DELAY_SECONDS` (ver `server.js:9`). El endpoint `/health` responde `503` durante los primeros N segundos.

```bash
# Probar localmente
docker run -d -p 3002:3000 --name inventario-delay \
  -e STARTUP_DELAY_SECONDS=10 inventario-app
curl -s -w "\nHTTP STATUS: %{http_code}\n" http://localhost:3002/health  # 503
sleep 10
curl -s -w "\nHTTP STATUS: %{http_code}\n" http://localhost:3002/health  # 200
docker stop inventario-delay && docker rm inventario-delay
```

**Activar en K8s:** editar `k8s/deployment-config.yaml`:
```yaml
data:
  STARTUP_DELAY_SECONDS: "15"
```
Luego: `kubectl apply -f k8s/deployment-config.yaml` + reiniciar deployment.

**⚠️ El `readinessProbe` en `deployment.yaml` ya está configurado para tolerarlo:**
- `initialDelaySeconds: 5` — espera 5s antes del primer probe
- `periodSeconds: 10` — cada 10s
- `failureThreshold: 6` — tolera hasta 6 fallos seguidos = 60s de tolerancia

**Para el informe:** "Si en vez de ajustar el probe se aumenta el número de réplicas, no se resuelve el problema: cada nuevo pod individualmente tarda en arrancar, y sin un readinessProbe tolerante, Kubernetes mataría y recrearía el pod (CrashLoopBackOff) porque nunca se marca como 'Ready'."

---

## PARTE II — Pruebas e Informe

### Métricas DORA

#### Lead Time for Changes

Tiempo entre commit y `kubectl set image` (o `kubectl apply`) en el clúster.

```bash
# Obtener timestamp del commit
git log --oneline --format="%H %ci" HEAD~5..HEAD

# Obtener timestamp del despliegue (de Actions o kubectl)
# Ejemplo: kubectl rollout history deployment/inventario-app
```

Completar tabla en README:
| Cambio | Commit Timestamp | Despliegue Timestamp | Lead Time |
|--------|-----------------|---------------------|-----------|
| v1 base | 2026-07-21 10:00 | 2026-07-21 10:15 | 15 min |
| v2 canary | 2026-07-22 14:30 | 2026-07-22 14:45 | 15 min |

#### Deployment Frequency

```bash
# Contar todas las veces que hiciste kubectl apply o kubectl set image
# Revisar historial:
kubectl rollout history deployment/inventario-app
```

| Métrica | Valor |
|---------|-------|
| Total despliegues | X |
| Días de trabajo | X |
| Frecuencia | X deploys/día |

#### Change Failure Rate

```bash
# De todos los despliegues, cuántos requirieron rollback o corrección
kubectl rollout history deployment/inventario-app
```

| Métrica | Valor |
|---------|-------|
| Total despliegues | X |
| Fallos/rollbacks | X |
| Tasa de fallo | X% |

---

### Documento de reflexión (PDF, 1-2 páginas)

Debe incluir:

1. **Justificación de estrategia** — ¿Por qué Canary sobre Blue-Green para esta app? (proporcionalidad del Service, riesgo mínimo, no duplicar infraestructura)

2. **Observación de persistencia** — Al eliminar el pod, los datos desaparecen porque `data/products.json` está en el filesystem efímero del pod. Sin PVC o DB externa, K8s siempre arranca desde la imagen original.

3. **Problemas reales encontrados** — Documenta al menos 1 error real:
   - Ej: "El build de Docker falló porque faltaba `data/` en el contexto"
   - Ej: "El Service canary no balanceaba porque los labels no coincidían"
   - Ej: "Trivy encontró una vulnerabilidad CRITICAL en `node:18-alpine` y tocó cambiar a `node:18-alpine3.18`"

---

## Checklist de entrega

- [ ] Repositorio público en GitHub
- [ ] `Dockerfile` multi-stage (builder testea, runtime copia solo necesario)
- [ ] `.github/workflows/ci-cd.yml` (build-test → build-push + Trivy)
- [ ] `k8s/deployment.yaml` (rolling update, probes, secrets)
- [ ] `k8s/service.yaml` (ClusterIP, puerto 80 → 3000)
- [ ] `k8s/canary/` o `k8s/blue-green/` con manifiestos
- [ ] Secret creado (API_KEY) y demostrado que no está en Git
- [ ] Arranque lento configurado y probado
- [ ] README actualizado con comandos exactos
- [ ] Documento PDF de reflexión con métricas DORA
- [ ] Evidencias: build local, pipeline verde, imagen en ghcr.io, rollout exitoso, tráfico canary

---

## Referencias de otras prácticas

| Práctica | Archivo útil | Concepto |
|----------|-------------|----------|
| `practica-transformacion` | `GUIA_SECRETS.md` | Secrets en K8s (YAML vs CLI, `stringData` vs `data`, inyección) |
| `practica-minikube` | `mi_primer_kubernets.md` | Conceptos básicos de K8s (Pods, Deployments, Services, ConfigMaps) |
| `practica-tolerancia-fallos` | `k8s/` | Probes avanzadas, health checks, despliegue multi-servicio |
| `practica-examen-ej` | `instructions.md` | Ejemplo de evaluación similar: errores comunes en Docker/K8s/CI |
| `practica-cloud-virtualization` | `AGENTS.md` | CI/CD con deploy a producción |

---

## Comandos rápidos de diagnóstico

```bash
# Ver todo el estado del clúster
kubectl get all

# Logs de un pod específico
kubectl logs -l app=inventario-app

# Describir un pod problemático
kubectl describe pod $(kubectl get pod -l app=inventario-app -o name | head -1)

# Probar Service internamente
kubectl run test-pod --rm -it --image=busybox -- wget -qO- http://inventario-app/health

# Rollback si algo sale mal
kubectl rollout undo deployment/inventario-app

# Escalar manualmente
kubectl scale deployment/inventario-app --replicas=3

# Ver eventos del namespace
kubectl get events --sort-by=.lastTimestamp
```

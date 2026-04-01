---
status: proposed
date: 2026-03-30
decision-makers: Equipo de Ingeniería
consulted: Tech Lead, DevOps, Producto/Negocio
informed: Equipo completo, Equipo de QA, Mantenedores de pipelines CI/CD
---

# ADR-001: Adoptar PostgreSQL 16 como base de datos para entornos de integración y producción

## Context and Problem Statement

El proyecto OWASP Juice Shop utiliza SQLite como base de datos principal a través de Sequelize ORM (`models/index.ts`). El dialecto y la ruta de almacenamiento están hardcodeados directamente en el código:

```typescript
// models/index.ts:30-40 — configuración actual hardcodeada
const sequelize = new Sequelize('database', 'username', 'password', {
  dialect: 'sqlite',
  storage: 'data/juiceshop.sqlite',
  ...
})
```

Además, el servidor usa `sequelize.sync({ force: true })` en cada arranque, lo que recrea el schema completo y elimina cualquier dato existente. Esto hace imposible mantener estado entre despliegues en ambientes de integración o producción.

¿Qué base de datos relacional y qué estrategia de gestión de schema deben adoptarse para ambientes de integración y producción, considerando las restricciones del stack actual (Node.js + Sequelize 6 + TypeScript)?

### Métricas de deuda técnica que motivan esta decisión

| Métrica | Valor actual |
|:--|:--|
| Vulnerabilidades | 22 |
| Security hotspots | 38 |
| Code smells | 454 |
| Code coverage | 43.2% |
| Complejidad ciclomática máxima (`routes/verify.ts`) | 160 |

## Decision Drivers

- **Concurrencia**: SQLite no soporta escrituras concurrentes; ambientes de integración con múltiples workers fallan con `SQLITE_BUSY`.
- **Paridad de entornos**: `sync({ force: true })` destruye datos en cada arranque; producción requiere migraciones incrementales.
- **Observabilidad**: PostgreSQL expone métricas (`pg_stat_activity`, `pg_stat_statements`) que SQLite no tiene.
- **Escalado**: PostgreSQL soporta conexiones concurrentes, connection pooling y replicación.
- **Reproducibilidad**: Se requiere una versión fija de motor de base de datos (PostgreSQL 16) en todos los ambientes.

## Considered Options

- **Opción A**: Mantener SQLite — sin cambios.
- **Opción B**: Migrar totalmente a PostgreSQL de una vez, eliminando SQLite.
- **Opción C**: Estrategia dual por fases — soporte de ambos dialectos con PostgreSQL como objetivo, SQLite como compatibilidad explícita para dev/test local.

## Decision Outcome

**Opción elegida: Opción C — Estrategia dual por fases.**

Justificación: Reduce el riesgo de regresión al permitir validación en ambos dialectos durante la transición. La migración total de una sola vez (Opción B) tiene alto riesgo dado que el codebase tiene 43.2% de cobertura de tests. Mantener solo SQLite (Opción A) bloquea mejoras operativas críticas.

Como parte de esta decisión, se introduce `sequelize-cli` para gestión de migraciones, eliminando la dependencia de `sequelize.sync({ force: true })` en ambientes que no sean desarrollo o testing.

**PostgreSQL objetivo: versión 16**, usada de forma consistente en desarrollo avanzado, CI y producción.

### Consequences

- Bien: mayor robustez en escenarios concurrentes (elimina errores `SQLITE_BUSY`).
- Bien: paridad entre ambientes de integración y producción.
- Bien: historial de schema versionado y auditable mediante `sequelize-cli`.
- Bien *(impacto en negocio)*: al eliminar `sync({ force: true })` en producción, los datos del usuario (sesiones, carritos, pedidos) persisten entre despliegues, lo que reduce interrupciones de servicio perceptibles para el usuario final y habilita despliegues sin downtime en el futuro.
- Bien *(impacto en negocio)*: PostgreSQL permite observabilidad de queries lentas (`pg_stat_statements`), lo que facilita identificar degradaciones de rendimiento antes de que afecten la experiencia del usuario.
- Mal: mayor complejidad operativa inicial (requiere instancia PostgreSQL en CI y producción).
- Mal: mayor costo de infraestructura por ambiente.
- Neutral: SQLite se mantiene como modo de compatibilidad explícita para laboratorio y uso educativo local.

### Non-Goals

- **MarsDB no se toca**: `data/mongodb.ts` (colecciones `reviews` y `orders`) queda fuera del alcance de esta decisión.
- **No se cambia el ORM**: Sequelize 6 se mantiene; no se migra a Prisma, Drizzle u otro.
- **No se migra datos existentes de SQLite a PostgreSQL**: la app recrea datos desde `data/datacreator.ts` en cada arranque; no hay datos de producción que preservar en esta fase.

## Implementation Plan

### Archivos afectados

| Archivo | Cambio requerido |
|:--|:--|
| `models/index.ts` | Reemplazar configuración hardcodeada por lectura de env vars; soportar ambos dialectos |
| `server.ts` | Cambiar `sequelize.sync({ force: true })` por ejecución de migraciones en producción; mantener sync solo para `NODE_ENV=test` o `NODE_ENV=development` |
| `package.json` | Agregar `pg`, `pg-hstore`, `sequelize-cli`; mantener `sqlite3` |
| `test/apiTestsSetup.ts` | Verificar que el setup de tests usa dialecto SQLite explícitamente via env var |
| `.env.example` | Crear o actualizar con las nuevas variables de entorno documentadas |
| `.github/workflows/ci.yml` | Agregar service de PostgreSQL 16; agregar job que ejecuta tests contra PostgreSQL |
| `migrations/` *(nuevo)* | Crear directorio con archivos de migración generados por `sequelize-cli` para cada modelo |
| `.sequelizerc` *(nuevo)* | Configurar paths de `sequelize-cli` (migrations, seeders, models, config) |
| `config/database.js` *(nuevo)* | Archivo de configuración de `sequelize-cli` que lee env vars por ambiente |

### Dependencias

Agregar a `package.json`:
```json
"pg": "^8.13.0",
"pg-hstore": "^2.3.4",
"sequelize-cli": "^6.6.2"
```

Mantener (no eliminar):
```json
"sqlite3": "^5.1.7"
```

### Variables de entorno

`DATABASE_URL` tiene prioridad sobre las variables separadas. Si `DATABASE_URL` no está definida, se usan las variables individuales como fallback.

```bash
# .env.example

# Opción A: URL completa (prioridad)
DATABASE_URL=postgres://juiceshop:password@localhost:5432/juiceshop

# Opción B: variables separadas (fallback si DATABASE_URL no está definida)
DB_DIALECT=sqlite           # 'sqlite' | 'postgres'
DB_HOST=localhost
DB_PORT=5432
DB_NAME=juiceshop
DB_USER=juiceshop
DB_PASSWORD=password

# SQLite (solo para dev/test)
DB_STORAGE=data/juiceshop.sqlite
```

### Lógica de configuración en `models/index.ts`

```typescript
// Pseudocódigo — patrón a seguir en models/index.ts
const isDatabaseUrl = !!process.env.DATABASE_URL
const dialect = isDatabaseUrl
  ? 'postgres'
  : (process.env.DB_DIALECT as Dialect) ?? 'sqlite'

const sequelize = isDatabaseUrl
  ? new Sequelize(process.env.DATABASE_URL, { dialect: 'postgres', logging: false })
  : new Sequelize({
      dialect,
      storage: dialect === 'sqlite' ? (process.env.DB_STORAGE ?? 'data/juiceshop.sqlite') : undefined,
      host: process.env.DB_HOST,
      port: Number(process.env.DB_PORT ?? 5432),
      database: process.env.DB_NAME,
      username: process.env.DB_USER,
      password: process.env.DB_PASSWORD,
      logging: false
    })
```

### Estrategia de sync vs. migraciones

| Ambiente (`NODE_ENV`) | Estrategia |
|:--|:--|
| `test` | `sequelize.sync({ force: true })` — se mantiene para velocidad en tests |
| `development` | `sequelize.sync({ force: true })` — se mantiene para arranque rápido local |
| `production` / `integration` | `sequelize-cli db:migrate` — nunca `sync({ force: true })` |

Modificar `server.ts` para detectar el ambiente y elegir la estrategia:
```typescript
if (process.env.NODE_ENV === 'production' || process.env.NODE_ENV === 'integration') {
  // ejecutar migraciones en lugar de sync
} else {
  await sequelize.sync({ force: true })
}
```

### Patrones a seguir

- Toda configuración de conexión va en `models/index.ts`; ningún modelo individual abre conexiones.
- Las migraciones generadas por `sequelize-cli` van en `migrations/`; no usar SQL raw en migraciones a menos que Sequelize QueryInterface no soporte la operación.
- Los seeders de datos van en `data/datacreator.ts` (patrón existente); no crear seeders de `sequelize-cli` para datos de la aplicación.

### Patrones a evitar

- No hardcodear `dialect: 'sqlite'` en ningún archivo fuera de tests.
- No llamar `sequelize.sync({ force: true })` en ambientes `production` o `integration`.
- No importar `pg` o `sqlite3` directamente en modelos; la conexión es exclusiva de `models/index.ts`.
- No reemplazar MarsDB (`data/mongodb.ts`) como parte de esta implementación.

### Configuración de CI (`.github/workflows/ci.yml`)

Agregar un service de PostgreSQL 16 y un job de tests separado:

```yaml
services:
  postgres:
    image: postgres:16
    env:
      POSTGRES_USER: juiceshop
      POSTGRES_PASSWORD: password
      POSTGRES_DB: juiceshop
    ports:
      - 5432:5432
    options: >-
      --health-cmd pg_isready
      --health-interval 10s
      --health-timeout 5s
      --health-retries 5
```

### Verification

- [ ] `npm test` pasa completamente con `DB_DIALECT=sqlite` (comportamiento actual sin regresiones)
- [ ] `npm test` pasa completamente con `DATABASE_URL=postgres://...` apuntando a PostgreSQL 16
- [ ] `npx sequelize-cli db:migrate` completa sin errores en una base de datos PostgreSQL 16 vacía
- [ ] `npx sequelize-cli db:migrate:undo:all` revierte todas las migraciones sin errores
- [ ] `models/index.ts` no contiene strings hardcodeados `'sqlite'` ni `'data/juiceshop.sqlite'` fuera de valores por defecto de env vars
- [ ] `server.ts` no llama `sequelize.sync({ force: true })` cuando `NODE_ENV=production`
- [ ] `.env.example` documenta todas las variables: `DATABASE_URL`, `DB_DIALECT`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_STORAGE`
- [ ] El job de CI en `.github/workflows/ci.yml` ejecuta tests contra PostgreSQL 16 con status verde
- [ ] No existen imports directos de `pg` o `sqlite3` fuera de `models/index.ts`
- [ ] `data/mongodb.ts` no fue modificado (MarsDB fuera de scope)

## Pros and Cons of the Options

### Opción A: Mantener SQLite

- Bueno: cero cambio inmediato, arranque local muy rápido.
- Bueno: sin costo de infraestructura adicional.
- Malo: errores `SQLITE_BUSY` en ambientes con múltiples workers concurrentes.
- Malo: `sync({ force: true })` hace imposible despliegues en producción sin pérdida de datos.
- Malo: sin paridad entre desarrollo avanzado y producción.

### Opción B: Migración total a PostgreSQL de una vez

- Bueno: estandarización rápida, sin complejidad de dialecto dual.
- Bueno: elimina inmediatamente la deuda de SQLite.
- Malo: alto riesgo de regresión dado el 43.2% de cobertura de tests actual.
- Malo: bloquea el flujo de desarrollo mientras se valida la migración completa.
- Malo: no permite rollback fácil si se encuentran incompatibilidades de dialecto.

### Opción C: Estrategia dual por fases *(elegida)*

- Bueno: permite validación en ambos dialectos; rollback posible durante transición.
- Bueno: introduce migraciones (`sequelize-cli`) como práctica sostenible a largo plazo.
- Bueno: adopción gradual reduce riesgo operativo.
- Malo: mayor complejidad temporal de configuración y pruebas.
- Neutral: SQLite permanece como opción, lo cual puede crear deuda si no se define fecha de retiro.

## More Information

### Riesgos

| Riesgo | Impacto | Mitigación |
|:--|:--|:--|
| Regresiones por diferencias de dialecto SQL | Alto | Tests en ambos dialectos durante transición (CI valida ambos) |
| Incompatibilidades de tipos (`BOOLEAN`, `DATE`, `TEXT` vs `VARCHAR`) entre dialectos | Alto | Auditoría de modelos antes de generar migraciones; pruebas de integración cubren tipos de datos |
| Costo operativo de PostgreSQL en CI | Medio | Usar `postgres:16` como service de GitHub Actions (sin costo adicional en GitHub-hosted runners) |
| Curva de aprendizaje de `sequelize-cli` | Medio | Documentar flujo en `CONTRIBUTING.md`; pairing durante primeras iteraciones |

#### Dragones: riesgos cross-dominio y de frontera de equipo

| Dragón | Dominio afectado | Por qué es oculto | Acción requerida |
|:--|:--|:--|:--|
| `datacreator.ts` asume `sync({ force: true })` | Equipo de QA / datos de prueba | La generación de datos de seed está acoplada al borrado total del schema en cada arranque. Si se introduce migraciones sin adaptar `datacreator.ts`, producción arranca sin datos iniciales. | Revisar y adaptar `data/datacreator.ts` para ejecutarse sobre un schema ya existente antes de activar migraciones en producción. Consultar a QA antes de cambiar el flujo. |
| Cambios en `ci.yml` afectan a todos los contribuidores del repositorio | Mantenedores de pipelines / contribuidores externos | El pipeline de CI es un recurso compartido; agregar el service de PostgreSQL puede incrementar tiempos de ejecución o romper jobs paralelos existentes. | Notificar a mantenedores de CI/CD antes de modificar `.github/workflows/ci.yml`. Validar que el nuevo job no rompe la matriz de tests existente. |
| MarsDB (`data/mongodb.ts`) comparte el proceso con Sequelize | Dominio de Reviews & Orders | Aunque MarsDB está fuera de scope, ambas bases de datos se inicializan en el mismo proceso en `server.ts`. Un error de conexión a PostgreSQL puede impedir que MarsDB arranque también. | Asegurar que el manejo de errores de conexión a PostgreSQL falla de forma aislada y no interrumpe la inicialización de MarsDB. Informar al responsable de ese dominio. |
| `finale-rest` genera endpoints REST desde modelos Sequelize | Equipo de API / consumidores del API | `finale-rest` depende de la instancia Sequelize. Cambios en el dialecto o en el timing de inicialización pueden romper endpoints REST generados automáticamente si el orden de inicialización cambia. | Incluir tests de integración de los endpoints REST generados por `finale-rest` en la suite de validación de PostgreSQL. |

### Condiciones para revisar esta decisión

- Si PostgreSQL introduce incompatibilidades con Sequelize 6 en versiones superiores a 16, se evaluará actualizar el ORM o fijar la versión de PostgreSQL.
- Si el costo de infraestructura de PostgreSQL supera el presupuesto de CI, se evaluará usar SQLite en modo WAL como alternativa de corto plazo.
- La fecha de retiro de SQLite como modo de compatibilidad debe definirse al completar la Fase 3 (adopción).

### Referencias

- `models/index.ts` — configuración actual de Sequelize (dialect hardcodeado en línea 31)
- `server.ts` — uso de `sequelize.sync({ force: true })`
- `test/apiTestsSetup.ts` — setup de tests que llama `server.start()`
- `data/mongodb.ts` — MarsDB (fuera de scope)
- `.github/workflows/ci.yml` — pipeline de CI a modificar
- `docs/adr/tech_debt_audit.md` — métricas de deuda técnica usadas como evidencia
- [Sequelize CLI docs](https://sequelize.org/docs/v6/other-topics/migrations/)
- [PostgreSQL 16 release notes](https://www.postgresql.org/docs/16/release-16.html)

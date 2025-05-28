# CutePanel Framework Open Source para Agentes de IA y Enjambres (Swarm)



**Sustantivo**
**Un potente framework multicadena, impulsado por la comunidad, para la innovación tecnológica en IA y Enjambres, potenciado por Julia.**

![CutePanel Banner](../../banner.png)

## Descripción General

CutePanel es un framework integral para construir aplicaciones descentralizadas (DApps) con un enfoque en arquitecturas basadas en agentes, inteligencia de enjambre y operaciones entre cadenas (cross-chain). Proporciona tanto una interfaz CLI para un despliegue rápido como una API de framework para implementaciones personalizadas. Al aprovechar agentes impulsados por IA y optimización de enjambres, CutePanel habilita estrategias sofisticadas a través de múltiples blockchains.

## Documentación

- 📖 [Visión General](https://cute-panel.gitbook.io/cute-panel-documentation-hub): Visión general y visión del proyecto
- 🤝 [Socios](https://cute-panel.gitbook.io/cute-panel-documentation-hub/partners-and-ecosystems/partners): Socios y Ecosistemas

### Técnico

- 🚀 [Primeros Pasos](https://cute-panel.gitbook.io/cute-panel-documentation-hub/technical/getting-started): Guía de inicio rápido
- 🏗️ [Arquitectura](https://cute-panel.gitbook.io/cute-panel-documentation-hub/technical/architecture): Descripción general de la arquitectura
- 🧑‍💻 [Hub de Desarrolladores](https://cute-panel.gitbook.io/cute-panel-documentation-hub/developer-hub): Para el desarrollador

### Características

- 🌟 [Características y Conceptos Clave](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/core-features-and-concepts): Características importantes y fundamentos
- 🤖 [Agentes](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/agents): Todo sobre los Agentes
- 🐝 [Enjambres (Swarms)](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/swarms): Todo sobre los Enjambres
- 🧠 [Redes Neuronales](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/neural-networks): Todo sobre las Redes Neuronales
- ⛓️ [Blockchains](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/blockchains-and-chains): Todas las blockchains donde puedes encontrar CutePanel
- 🌉 [Puentes (Bridges)](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/bridges-cross-chain): Notas e información importante sobre puentes
- 🔌 [Integraciones](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/integrations): Todas las formas de integraciones
- 💾 [Almacenamiento (Storage)](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/storage): Diferentes tipos de almacenamiento
- 👛 [Billeteras (Wallets)](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/wallets): Billeteras soportadas
- 🚩 [Casos de Uso](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/use-cases): Todos los casos de uso y ejemplos
- 🔵 [API](https://cute-panel.gitbook.io/cute-panel-documentation-hub/api-documentation/api-reference): Referencia de la API del backend de Julia

## Inicio Rápido

### Prerrequisitos

- **Node.js**: Asegúrate de tener Node.js instalado. Puedes descargarlo desde [nodejs.org](https://nodejs.org/).
- **Julia**: Asegúrate de tener Julia instalado. Puedes descargarlo desde [julialang.org](https://julialang.org/).
- **Python**: Asegúrate de tener Python instalado. Puedes descargarlo desde [python.org](https://www.python.org/).

### Creación de Agentes y Enjambres (TypeScript & Python)

#### Agentes y Enjambres TypeScript (TS)

1.  **Instala las dependencias y construye el proyecto:**
    ```bash
    npm install
    npm run build
    ```

2.  **Crea un nuevo agente o enjambre usando las plantillas proporcionadas:**
    -   Copia y personaliza la plantilla en `packages/modules/julia_templates/custom_agent_template.jl` para agentes basados en Julia.
    -   Para agentes TypeScript, usa las plantillas en `packages/templates/agents/` (ej., `custom_agent_template.jl`, `src/AgentsService.ts`).

3.  **Configura tu agente o enjambre:**
    -   Edita los archivos de configuración o pasa parámetros en tu código TypeScript.
    -   Usa el SDK de TypeScript (`packages/core/src/api/ApiClient.ts`) para interactuar con el backend de Julia, crear agentes, enviar objetivos y gestionar enjambres.

4.  **Ejecuta tu agente o enjambre:**
    -   Usa la CLI o tu propio script para iniciar el agente.
    -   Ejemplo (TypeScript):
        ```typescript
        import { ApiClient } from '@cutepanel/core';
        const client = new ApiClient();
        // Crea y ejecuta la lógica del agente aquí
        ```

#### Agentes y Enjambres Python

1.  **Instala el wrapper de Python:**
    ```bash
    pip install -e ./packages/pythonWrapper
    ```

2.  **Crea un nuevo agente o enjambre usando las plantillas de Python:**
    -   Usa las plantillas en `packages/templates/python_templates/` (ej., `orchestration_template.py`, `llm_integration_examples/`).

3.  **Configura y ejecuta tu agente:**
    -   Importa el wrapper de Python y usa el cliente para interactuar con CutePanel.
    -   Ejemplo:
        ```python
        from cutepanel_wrapper import client
        api = client.CutePanelApiClient()
        # Crea y ejecuta la lógica del agente aquí
        ```

4.  **Envía objetivos o gestiona enjambres:**
    -   Usa la API de Python para enviar objetivos, crear enjambres y monitorizar resultados.

## Descripción General de la Arquitectura

CutePanel está construido como un sistema modular y multicapa para aplicaciones cross-chain, basadas en agentes y de inteligencia de enjambre. La arquitectura está diseñada para la extensibilidad, seguridad y alto rendimiento, soportando los ecosistemas EVM y Solana.

**Capas Clave:**

-   **Lógica de Usuario & SDKs**
    -   **SDK de TypeScript & Capa de Lógica:**
        -   Ubicación: `packages/core/`, `packages/templates/agents/`
        -   Los usuarios escriben la lógica de agentes y enjambres en TypeScript, usando el SDK para interactuar con el backend de Julia.
    -   **Wrapper/SDK de Python & Capa de Lógica:**
        -   Ubicación: `packages/pythonWrapper/`, `packages/templates/python_templates/`
        -   Los usuarios escriben la lógica de agentes y orquestación en Python, usando el wrapper para interactuar con CutePanel.

-   **Backend de CutePanel**
    -   **Capa 1: Motor Principal de Julia (Capa Fundamental):**
        -   Ubicación: `julia/src/`
        -   Implementa la lógica principal del backend: orquestación de agentes, algoritmos de enjambre, redes neuronales, optimización de portafolios, integración con blockchain/DEX, feeds de precios, almacenamiento y estrategias de trading.
    -   **Capa 2: Capa API de Julia (Capa de Interfaz, Habilitada para MCP):**
        -   Ubicación: `julia/src/api/`
        -   Expone toda la funcionalidad del backend a través de endpoints API (REST/gRPC/MCP), valida y despacha solicitudes, formatea respuestas y aplica seguridad a nivel de API.
    -   **Capa 3: Componente de Seguridad de Rust (Capa de Seguridad Especializada):**
        -   Ubicación: `packages/rust_signer/`
        -   Maneja todas las operaciones criptográficas (gestión de claves privadas, firma de transacciones, derivación de billeteras HD) en un entorno seguro y con memoria segura, llamado mediante FFI desde Julia.

-   **Integraciones DEX**
    -   Soporte DEX modular para Uniswap, SushiSwap, PancakeSwap, QuickSwap, TraderJoe (EVM) y Raydium (Solana) a través de módulos dedicados en `julia/src/dex/`.
    -   Cada módulo DEX implementa la interfaz AbstractDEX para precios, liquidez, creación de órdenes, historial de transacciones y descubrimiento de tokens/pares.

-   **Gestión de Riesgos & Analíticas**
    -   La gestión global de riesgos se aplica a través de `config/risk_management.toml` y `julia/src/trading/RiskManagement.jl`.
    -   El registro y análisis de transacciones en tiempo real son proporcionados por `julia/src/trading/TradeLogger.jl`, con salida tanto a la consola como a un archivo.

-   **Comunidad & Contribución**
    -   Desarrollo de código abierto, impulsado por la comunidad con directrices claras de contribución y puntos de extensión modulares para nuevos agentes, DEXes y analíticas.

**Diagrama de Arquitectura:**

```mermaid
flowchart TD
    subgraph "Lógica de Usuario & SDKs (User Logic & SDKs)"
        TS[Lógica de Agente/Enjambre TypeScript (TypeScript Agent/Swarm Logic)] --> TS_SDK[SDK TS]
        Py[Lógica de Agente/Enjambre Python (Python Agent/Swarm Logic)] --> Py_SDK[Wrapper/SDK de Python (Python Wrapper/SDK)]
    end

    subgraph "Backend de CutePanel (CutePanel Backend)"
        API[Capa API de Julia (Julia API Layer)]
        Core[Motor Principal de Julia (Julia Core Engine)]
        Rust[Firmador Seguro de Rust (Secure Rust Signer)]
    end

    subgraph "Integraciones DEX (DEX Integrations)"
        Uniswap[UniswapDEX]
        SushiSwap[SushiSwapDEX]
        PancakeSwap[PancakeSwapDEX]
        QuickSwap[QuickSwapDEX]
        TraderJoe[TraderJoeDEX]
        %% This line is fixed: text enclosed in quotes
        Raydium["RaydiumDEX (Solana, via Python FFI)"]
    end

    %% Connections
    TS_SDK --> API
    Py_SDK --> API
    API --> Core
    Core --> Rust
    Core --> Uniswap
    Core --> SushiSwap
    Core --> PancakeSwap
    Core --> QuickSwap
    Core --> TraderJoe
    Core --> Raydium

🧑‍🤝‍🧑 Comunidad & Contribución
¡CutePanel es un proyecto de código abierto y damos la bienvenida a las contribuciones de la comunidad! Ya seas un desarrollador, un investigador o un entusiasta de las tecnologías descentralizadas, la IA y blockchain, hay muchas maneras de involucrarse.

Únete a Nuestra Comunidad
El centro principal de la comunidad CutePanel es nuestro repositorio de GitHub:

Repositorio de GitHub: https://github.com/KatriaDopex/CutePanel
Incidencias (Issues): Reporta errores, solicita características o discute desafíos técnicos específicos.
Discusiones (Discussions): (Considera habilitar las Discusiones de GitHub) Para preguntas más amplias, ideas y conversaciones comunitarias.
Pull Requests: Contribuye con código, documentación y mejoras.
Formas de Contribuir
Apreciamos todas las formas de contribución, incluyendo pero no limitándose a:

💻 Contribuciones de Código:
Implementar nuevas características para agentes, enjambres o capacidades de redes neuronales.
Añadir soporte para nuevas blockchains o puentes.
Mejorar el código existente, el rendimiento o la seguridad.
Escribir pruebas unitarias y de integración.
Desarrollar nuevos casos de uso o aplicaciones de ejemplo.
📖 Documentación:
Mejorar la documentación existente para mayor claridad e integridad.
Escribir nuevos tutoriales o guías.
Añadir ejemplos a la referencia de la API.
Traducir la documentación.
🐞 Reportes de Errores & Pruebas:
Identificar y reportar errores con pasos claros de reproducción.
Ayudar a probar nuevas versiones y características.
💡 Ideas & Feedback:
Sugerir nuevas características o mejoras.
Proporcionar feedback sobre la dirección y usabilidad del proyecto.
📣 Evangelización & Promoción:
Difundir la palabra sobre CutePanel.
Escribir artículos de blog o crear videos sobre tus experiencias con CutePanel.
Empezando con las Contribuciones
Configura Tu Entorno: Sigue el Inicio Rápido
Encuentra una Incidencia: Navega por la página de Incidencias de GitHub. Busca incidencias etiquetadas con good first issue (buena primera incidencia) o help wanted (se busca ayuda) si eres nuevo.
Discute Tus Planes: Para nuevas características o cambios significativos, es una buena idea abrir primero una incidencia para discutir tus ideas con los mantenedores y la comunidad.
Flujo de Trabajo de Contribución:
Haz un "fork" del repositorio de CutePanel a tu propia cuenta de GitHub.
Crea una nueva rama para tus cambios (ej., git checkout -b feature/my-new-feature o fix/bug-description).
Realiza tus cambios, adhiriéndote a cualquier guía de estilo de codificación (a definir, ver abajo).
Escribe o actualiza pruebas para tus cambios.
Haz "commit" de tus cambios con mensajes de commit claros y descriptivos.
Haz "push" de tu rama a tu "fork" en GitHub.
Abre un Pull Request (PR) contra la rama main o la rama de desarrollo apropiada del repositorio KatriaDopex/CutePanel.
Describe claramente los cambios en tu PR y enlaza a cualquier incidencia relevante.
Sé receptivo al feedback y participa en el proceso de revisión.
Guías de Contribución
Estamos en proceso de formalizar nuestras guías de contribución. Mientras tanto, por favor intenta:

Código Claro: Escribe código legible y mantenible. Añade comentarios donde sea necesario.
Pruebas: Incluye pruebas para nuevas funcionalidades y correcciones de errores.
Mensajes de Commit: Escribe mensajes de commit claros y concisos (ej., siguiendo Conventional Commits).
Planeamos crear un archivo CONTRIBUTING.md con guías detalladas pronto.

Código de Conducta
Estamos comprometidos a fomentar una comunidad abierta, acogedora e inclusiva. Se espera que todos los contribuidores y participantes se adhieran a un Código de Conducta. Planeamos adoptar y publicar un archivo CODE_OF_CONDUCT.md (ej., basado en el Contributor Covenant) en un futuro cercano.
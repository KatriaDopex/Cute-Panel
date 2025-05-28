# CutePanel Open Source AI Agent & Swarm Framework



**Substantiv**
**Ein leistungsstarkes, Community-getriebenes Multi-Chain-Framework für technologische Innovationen in KI und Schwarmintelligenz, angetrieben von Julia.**

![CutePanel Banner](../../banner.png)

## Überblick

CutePanel ist ein umfassendes Framework zur Erstellung dezentraler Anwendungen (DApps) mit Fokus auf agentenbasierten Architekturen, Schwarmintelligenz und Cross-Chain-Operationen. Es bietet sowohl eine CLI-Schnittstelle für die schnelle Bereitstellung als auch eine Framework-API für benutzerdefinierte Implementierungen. Durch den Einsatz von KI-gestützten Agenten und Schwarmoptimierung ermöglicht CutePanel anspruchsvolle Strategien über mehrere Blockchains hinweg.

## Dokumentation

- 📖 [Überblick](https://cute-panel.gitbook.io/cute-panel-documentation-hub): Projektübersicht und Vision
- 🤝 [Partner](https://cute-panel.gitbook.io/cute-panel-documentation-hub/partners-and-ecosystems/partners): Partner & Ökosysteme

### Technisch

- 🚀 [Erste Schritte](https://cute-panel.gitbook.io/cute-panel-documentation-hub/technical/getting-started): Schnellstartanleitung
- 🏗️ [Architektur](https://cute-panel.gitbook.io/cute-panel-documentation-hub/technical/architecture): Architekturübersicht
- 🧑‍💻 [Entwickler-Hub](https://cute-panel.gitbook.io/cute-panel-documentation-hub/developer-hub): Für den Entwickler

### Funktionen

- 🌟 [Kernfunktionen & Konzepte](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/core-features-and-concepts): Wichtige Funktionen und Grundlagen
- 🤖 [Agenten](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/agents): Alles über Agenten
- 🐝 [Schwärme (Swarms)](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/swarms): Alles über Schwärme
- 🧠 [Neuronale Netze](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/neural-networks): Alles über Neuronale Netze
- ⛓️ [Blockchains](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/blockchains-and-chains): Alle Blockchains, auf denen Sie CutePanel finden können
- 🌉 [Bridges (Brücken)](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/bridges-cross-chain): Wichtige Hinweise und Informationen zu Bridges
- 🔌 [Integrationen](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/integrations): Alle Formen von Integrationen
- 💾 [Speicher (Storage)](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/storage): Verschiedene Arten von Speicher
- 👛 [Wallets](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/wallets): Unterstützte Wallets
- 🚩 [Anwendungsfälle (Use Cases)](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/use-cases): Alle Anwendungsfälle und Beispiele
- 🔵 [API](https://cute-panel.gitbook.io/cute-panel-documentation-hub/api-documentation/api-reference): Julia Backend API-Referenz

## Schnellstart

### Voraussetzungen

- **Node.js**: Stellen Sie sicher, dass Node.js installiert ist. Sie können es von [nodejs.org](https://nodejs.org/) herunterladen.
- **Julia**: Stellen Sie sicher, dass Julia installiert ist. Sie können es von [julialang.org](https://julialang.org/) herunterladen.
- **Python**: Stellen Sie sicher, dass Python installiert ist. Sie können es von [python.org](https://www.python.org/) herunterladen.

### Erstellen von Agenten und Schwärmen (TypeScript & Python)

#### TypeScript (TS) Agenten & Schwärme

1.  **Abhängigkeiten installieren und das Projekt bauen:**
    ```bash
    npm install
    npm run build
    ```

2.  **Erstellen Sie einen neuen Agenten oder Schwarm mithilfe der bereitgestellten Vorlagen:**
    -   Kopieren und passen Sie die Vorlage in `packages/modules/julia_templates/custom_agent_template.jl` für Julia-basierte Agenten an.
    -   Verwenden Sie für TypeScript-Agenten die Vorlagen in `packages/templates/agents/` (z. B. `custom_agent_template.jl`, `src/AgentsService.ts`).

3.  **Konfigurieren Sie Ihren Agenten oder Schwarm:**
    -   Bearbeiten Sie die Konfigurationsdateien oder übergeben Sie Parameter in Ihrem TypeScript-Code.
    -   Verwenden Sie das TypeScript SDK (`packages/core/src/api/ApiClient.ts`), um mit dem Julia-Backend zu interagieren, Agenten zu erstellen, Ziele zu übermitteln und Schwärme zu verwalten.

4.  **Führen Sie Ihren Agenten oder Schwarm aus:**
    -   Verwenden Sie die CLI oder Ihr eigenes Skript, um den Agenten zu starten.
    -   Beispiel (TypeScript):
        ```typescript
        import { ApiClient } from '@cutepanel/core';
        const client = new ApiClient();
        // Erstellen und Ausführen der Agentenlogik hier
        ```

#### Python Agenten & Schwärme

1.  **Installieren Sie den Python-Wrapper:**
    ```bash
    pip install -e ./packages/pythonWrapper
    ```

2.  **Erstellen Sie einen neuen Agenten oder Schwarm mithilfe der Python-Vorlagen:**
    -   Verwenden Sie die Vorlagen in `packages/templates/python_templates/` (z. B. `orchestration_template.py`, `llm_integration_examples/`).

3.  **Konfigurieren und führen Sie Ihren Agenten aus:**
    -   Importieren Sie den Python-Wrapper und verwenden Sie den Client, um mit CutePanel zu interagieren.
    -   Beispiel:
        ```python
        from cutepanel_wrapper import client
        api = client.CutePanelApiClient()
        # Erstellen und Ausführen der Agentenlogik hier
        ```

4.  **Übermitteln Sie Ziele oder verwalten Sie Schwärme:**
    -   Verwenden Sie die Python-API, um Ziele zu übermitteln, Schwärme zu erstellen und Ergebnisse zu überwachen.

## Architekturübersicht

CutePanel ist als modulares, mehrschichtiges System für Cross-Chain-, agentenbasierte und Schwarmintelligenz-Anwendungen aufgebaut. Die Architektur ist auf Erweiterbarkeit, Sicherheit und hohe Leistung ausgelegt und unterstützt sowohl EVM- als auch Solana-Ökosysteme.

**Wichtige Schichten:**

-   **Benutzerlogik & SDKs**
    -   **TypeScript SDK & Logikschicht:**
        -   Ort: `packages/core/`, `packages/templates/agents/`
        -   Benutzer schreiben Agenten- und Schwarmlogik in TypeScript und verwenden das SDK zur Interaktion mit dem Julia-Backend.
    -   **Python Wrapper/SDK & Logikschicht:**
        -   Ort: `packages/pythonWrapper/`, `packages/templates/python_templates/`
        -   Benutzer schreiben Agenten- und Orchestrierungslogik in Python und verwenden den Wrapper zur Interaktion mit CutePanel.

-   **CutePanel Backend**
    -   **Schicht 1: Julia Core Engine (Grundlagenschicht):**
        -   Ort: `julia/src/`
        -   Implementiert die Kern-Backend-Logik: Agentenorchestrierung, Schwarmalgorithmen, neuronale Netze, Portfoliooptimierung, Blockchain-/DEX-Integration, Preis-Feeds, Speicherung und Handelsstrategien.
    -   **Schicht 2: Julia API-Schicht (Schnittstellenschicht, MCP-fähig):**
        -   Ort: `julia/src/api/`
        -   Stellt alle Backend-Funktionen über API-Endpunkte (REST/gRPC/MCP) bereit, validiert und verteilt Anfragen, formatiert Antworten und setzt Sicherheit auf API-Ebene durch.
    -   **Schicht 3: Rust-Sicherheitskomponente (Spezialisierte Sicherheitsschicht):**
        -   Ort: `packages/rust_signer/`
        -   Verarbeitet alle kryptografischen Operationen (Verwaltung privater Schlüssel, Transaktionssignierung, HD-Wallet-Ableitung) in einer sicheren, speichersicheren Umgebung, die über FFI von Julia aufgerufen wird.

-   **DEX-Integrationen**
    -   Modulare DEX-Unterstützung für Uniswap, SushiSwap, PancakeSwap, QuickSwap, TraderJoe (EVM) und Raydium (Solana) über dedizierte Module in `julia/src/dex/`.
    -   Jedes DEX-Modul implementiert die AbstractDEX-Schnittstelle für Preis, Liquidität, Auftragserstellung, Handelshistorie und Token-/Paar-Entdeckung.

-   **Risikomanagement & Analytik**
    -   Globales Risikomanagement wird über `config/risk_management.toml` und `julia/src/trading/RiskManagement.jl` durchgesetzt.
    -   Echtzeit-Handelsprotokollierung und -analysen werden von `julia/src/trading/TradeLogger.jl` bereitgestellt und sowohl an die Konsole als auch in eine Datei ausgegeben.

-   **Community & Beitrag**
    -   Open-Source, Community-getriebene Entwicklung mit klaren Beitragsrichtlinien und modularen Erweiterungspunkten für neue Agenten, DEXes und Analysen.

**Architekturdiagramm:**

```mermaid
flowchart TD
    subgraph "Benutzerlogik & SDKs (User Logic & SDKs)"
        TS[TypeScript Agenten-/Schwarmlogik (TypeScript Agent/Swarm Logic)] --> TS_SDK[TS SDK]
        Py[Python Agenten-/Schwarmlogik (Python Agent/Swarm Logic)] --> Py_SDK[Python Wrapper/SDK]
    end

    subgraph "CutePanel Backend"
        API[Julia API-Schicht (Julia API Layer)]
        Core[Julia Core Engine]
        Rust[Sicherer Rust Signer (Secure Rust Signer)]
    end

    subgraph "DEX-Integrationen (DEX Integrations)"
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

🧑‍🤝‍🧑 Community & Beitrag
CutePanel ist ein Open-Source-Projekt, und wir freuen uns über Beiträge aus der Community! Egal, ob Sie Entwickler, Forscher oder ein Enthusiast für dezentrale Technologien, KI und Blockchain sind, es gibt viele Möglichkeiten, sich zu beteiligen.

Treten Sie unserer Community bei
Der primäre Hub für die CutePanel-Community ist unser GitHub-Repository:

GitHub-Repository: https://github.com/KatriaDopex/CutePanel
Issues (Probleme): Melden Sie Fehler, fordern Sie Funktionen an oder diskutieren Sie spezifische technische Herausforderungen.
Discussions (Diskussionen): (Erwägen Sie die Aktivierung von GitHub Discussions) Für umfassendere Fragen, Ideen und Community-Gespräche.
Pull Requests: Tragen Sie Code, Dokumentation und Verbesserungen bei.
Möglichkeiten zum Beitragen
Wir schätzen alle Formen von Beiträgen, einschließlich, aber nicht beschränkt auf:

💻 Code-Beiträge:
Implementierung neuer Funktionen für Agenten, Schwärme oder neuronale Netzwerkfähigkeiten.
Hinzufügen von Unterstützung für neue Blockchains oder Bridges.
Verbesserung von vorhandenem Code, Leistung oder Sicherheit.
Schreiben von Unit- und Integrationstests.
Entwicklung neuer Anwendungsfälle oder Beispielanwendungen.
📖 Dokumentation:
Verbesserung der vorhandenen Dokumentation hinsichtlich Klarheit und Vollständigkeit.
Schreiben neuer Tutorials oder Anleitungen.
Hinzufügen von Beispielen zur API-Referenz.
Übersetzung der Dokumentation.
🐞 Fehlerberichte & Tests:
Identifizierung und Meldung von Fehlern mit klaren Reproduktionsschritten.
Hilfe beim Testen neuer Releases und Funktionen.
💡 Ideen & Feedback:
Vorschlagen neuer Funktionen oder Verbesserungen.
Bereitstellung von Feedback zur Ausrichtung und Benutzerfreundlichkeit des Projekts.
📣 Evangelismus & Interessenvertretung:
Verbreiten Sie die Nachricht über CutePanel.
Schreiben Sie Blogbeiträge oder erstellen Sie Videos über Ihre Erfahrungen mit CutePanel.
Erste Schritte für Beiträge
Richten Sie Ihre Umgebung ein: Folgen Sie dem Schnellstart
Finden Sie ein Issue: Durchsuchen Sie die GitHub Issues Seite. Suchen Sie nach Issues, die mit good first issue (gutes erstes Issue) oder help wanted (Hilfe gesucht) gekennzeichnet sind, wenn Sie neu sind.
Diskutieren Sie Ihre Pläne: Für neue Funktionen oder wesentliche Änderungen ist es eine gute Idee, zuerst ein Issue zu eröffnen, um Ihre Ideen mit den Maintainern und der Community zu diskutieren.
Beitragsworkflow:
Forken Sie das CutePanel-Repository in Ihr eigenes GitHub-Konto.
Erstellen Sie einen neuen Branch für Ihre Änderungen (z. B. git checkout -b feature/my-new-feature oder fix/bug-description).
Nehmen Sie Ihre Änderungen vor und halten Sie sich dabei an etwaige Coding-Style-Richtlinien (noch zu definieren, siehe unten).
Schreiben oder aktualisieren Sie Tests für Ihre Änderungen.
Committen Sie Ihre Änderungen mit klaren und beschreibenden Commit-Nachrichten.
Pushen Sie Ihren Branch zu Ihrem Fork auf GitHub.
Öffnen Sie einen Pull Request (PR) gegen den main-Branch oder den entsprechenden Entwicklungsbranch des KatriaDopex/CutePanel-Repositorys.
Beschreiben Sie die Änderungen in Ihrem PR klar und verlinken Sie auf relevante Issues.
Reagieren Sie auf Feedback und nehmen Sie am Review-Prozess teil.
Beitragsrichtlinien
Wir sind dabei, unsere Beitragsrichtlinien zu formalisieren. In der Zwischenzeit streben Sie bitte Folgendes an:

Klarer Code: Schreiben Sie lesbaren und wartbaren Code. Fügen Sie bei Bedarf Kommentare hinzu.
Tests: Fügen Sie Tests für neue Funktionen und Fehlerbehebungen hinzu.
Commit-Nachrichten: Schreiben Sie klare und prägnante Commit-Nachrichten (z. B. gemäß Conventional Commits).
Wir planen, bald eine CONTRIBUTING.md-Datei mit detaillierten Richtlinien zu erstellen.

Verhaltenskodex
Wir verpflichten uns, eine offene, einladende und integrative Community zu fördern. Von allen Beitragenden und Teilnehmern wird erwartet, dass sie sich an einen Verhaltenskodex halten. Wir planen, in naher Zukunft eine CODE_OF_CONDUCT.md-Datei (z. B. basierend auf dem Contributor Covenant) zu verabschieden und zu veröffentlichen.
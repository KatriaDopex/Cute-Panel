# CutePanel Framework Open Source pour Agent IA & Essaim (Swarm)



**Nom**
**Un framework multi-chaînes puissant, axé sur la communauté, pour l'innovation technologique en IA et Essaim, propulsé par Julia.**

![CutePanel Banner](../../banner.png)

## Aperçu

CutePanel est un framework complet pour la création d'applications décentralisées (DApps) axé sur les architectures basées sur des agents, l'intelligence en essaim et les opérations inter-chaînes. Il fournit à la fois une interface CLI pour un déploiement rapide et une API de framework pour des implémentations personnalisées. En exploitant des agents alimentés par l'IA et l'optimisation des essaims, CutePanel permet des stratégies sophistiquées sur plusieurs blockchains.

## Documentation

- 📖 [Vue d'ensemble](https://cute-panel.gitbook.io/cute-panel-documentation-hub) : Vue d'ensemble et vision du projet
- 🤝 [Partenaires](https://cute-panel.gitbook.io/cute-panel-documentation-hub/partners-and-ecosystems/partners) : Partenaires et Écosystèmes

### Technique

- 🚀 [Démarrage Rapide](https://cute-panel.gitbook.io/cute-panel-documentation-hub/technical/getting-started) : Guide de démarrage rapide
- 🏗️ [Architecture](https://cute-panel.gitbook.io/cute-panel-documentation-hub/technical/architecture) : Vue d'ensemble de l'architecture
- 🧑‍💻 [Hub Développeur](https://cute-panel.gitbook.io/cute-panel-documentation-hub/developer-hub) : Pour le développeur

### Fonctionnalités

- 🌟 [Fonctionnalités et Concepts Clés](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/core-features-and-concepts) : Fonctionnalités importantes et fondamentaux
- 🤖 [Agents](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/agents) : Tout sur les Agents
- 🐝 [Essaims (Swarms)](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/swarms) : Tout sur les Essaims
- 🧠 [Réseaux Neuronaux](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/neural-networks) : Tout sur les Réseaux Neuronaux
- ⛓️ [Blockchains](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/blockchains-and-chains) : Toutes les blockchains où vous pouvez trouver CutePanel
- 🌉 [Ponts (Bridges)](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/bridges-cross-chain) : Notes et informations importantes sur les ponts
- 🔌 [Intégrations](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/integrations) : Toutes les formes d'intégrations
- 💾 [Stockage (Storage)](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/storage) : Différents types de stockage
- 👛 [Portefeuilles (Wallets)](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/wallets) : Portefeuilles pris en charge
- 🚩 [Cas d'Utilisation (Use Cases)](https://cute-panel.gitbook.io/cute-panel-documentation-hub/features/use-cases) : Tous les cas d'utilisation et exemples
- 🔵 [API](https://cute-panel.gitbook.io/cute-panel-documentation-hub/api-documentation/api-reference) : Référence de l'API backend Julia

## Démarrage Rapide

### Prérequis

- **Node.js** : Assurez-vous que Node.js est installé. Vous pouvez le télécharger sur [nodejs.org](https://nodejs.org/).
- **Julia** : Assurez-vous que Julia est installé. Vous pouvez le télécharger sur [julialang.org](https://julialang.org/).
- **Python** : Assurez-vous que Python est installé. Vous pouvez le télécharger sur [python.org](https://www.python.org/).

### Création d'Agents et d'Essaims (TypeScript & Python)

#### Agents & Essaims TypeScript (TS)

1.  **Installez les dépendances et construisez le projet :**
    ```bash
    npm install
    npm run build
    ```

2.  **Créez un nouvel agent ou essaim en utilisant les modèles fournis :**
    -   Copiez et personnalisez le modèle dans `packages/modules/julia_templates/custom_agent_template.jl` pour les agents basés sur Julia.
    -   Pour les agents TypeScript, utilisez les modèles dans `packages/templates/agents/` (par exemple, `custom_agent_template.jl`, `src/AgentsService.ts`).

3.  **Configurez votre agent ou essaim :**
    -   Modifiez les fichiers de configuration ou passez des paramètres dans votre code TypeScript.
    -   Utilisez le SDK TypeScript (`packages/core/src/api/ApiClient.ts`) pour interagir avec le backend Julia, créer des agents, soumettre des objectifs et gérer les essaims.

4.  **Exécutez votre agent ou essaim :**
    -   Utilisez la CLI ou votre propre script pour démarrer l'agent.
    -   Exemple (TypeScript) :
        ```typescript
        import { ApiClient } from '@cutepanel/core';
        const client = new ApiClient();
        // Créez et exécutez la logique de l'agent ici
        ```

#### Agents & Essaims Python

1.  **Installez le wrapper Python :**
    ```bash
    pip install -e ./packages/pythonWrapper
    ```

2.  **Créez un nouvel agent ou essaim en utilisant les modèles Python :**
    -   Utilisez les modèles dans `packages/templates/python_templates/` (par exemple, `orchestration_template.py`, `llm_integration_examples/`).

3.  **Configurez et exécutez votre agent :**
    -   Importez le wrapper Python et utilisez le client pour interagir avec CutePanel.
    -   Exemple :
        ```python
        from cutepanel_wrapper import client
        api = client.CutePanelApiClient()
        # Créez et exécutez la logique de l'agent ici
        ```

4.  **Soumettez des objectifs ou gérez les essaims :**
    -   Utilisez l'API Python pour soumettre des objectifs, créer des essaims et surveiller les résultats.

## Vue d'ensemble de l'Architecture

CutePanel est construit comme un système modulaire multi-couches pour les applications inter-chaînes, basées sur des agents et d'intelligence en essaim. L'architecture est conçue pour l'extensibilité, la sécurité et la haute performance, prenant en charge les écosystèmes EVM et Solana.

**Couches Clés :**

-   **Logique Utilisateur & SDKs**
    -   **SDK TypeScript & Couche Logique :**
        -   Emplacement : `packages/core/`, `packages/templates/agents/`
        -   Les utilisateurs écrivent la logique des agents et des essaims en TypeScript, en utilisant le SDK pour interagir avec le backend Julia.
    -   **Wrapper/SDK Python & Couche Logique :**
        -   Emplacement : `packages/pythonWrapper/`, `packages/templates/python_templates/`
        -   Les utilisateurs écrivent la logique des agents et d'orchestration en Python, en utilisant le wrapper pour interagir avec CutePanel.

-   **Backend CutePanel**
    -   **Couche 1 : Moteur Principal Julia (Couche Fondatrice) :**
        -   Emplacement : `julia/src/`
        -   Implémente la logique backend principale : orchestration d'agents, algorithmes d'essaim, réseaux neuronaux, optimisation de portefeuille, intégration blockchain/DEX, flux de prix, stockage et stratégies de trading.
    -   **Couche 2 : Couche API Julia (Couche d'Interface, compatible MCP) :**
        -   Emplacement : `julia/src/api/`
        -   Expose toutes les fonctionnalités backend via des points de terminaison API (REST/gRPC/MCP), valide et distribue les requêtes, formate les réponses et applique la sécurité au niveau de l'API.
    -   **Couche 3 : Composant de Sécurité Rust (Couche de Sécurité Spécialisée) :**
        -   Emplacement : `packages/rust_signer/`
        -   Gère toutes les opérations cryptographiques (gestion des clés privées, signature des transactions, dérivation de portefeuille HD) dans un environnement sécurisé et à mémoire sûre, appelé via FFI depuis Julia.

-   **Intégrations DEX**
    -   Support DEX modulaire pour Uniswap, SushiSwap, PancakeSwap, QuickSwap, TraderJoe (EVM), et Raydium (Solana) via des modules dédiés dans `julia/src/dex/`.
    -   Chaque module DEX implémente l'interface AbstractDEX pour le prix, la liquidité, la création d'ordres, l'historique des transactions et la découverte de jetons/paires.

-   **Gestion des Risques & Analyses**
    -   La gestion globale des risques est appliquée via `config/risk_management.toml` et `julia/src/trading/RiskManagement.jl`.
    -   La journalisation et l'analyse des transactions en temps réel sont fournies par `julia/src/trading/TradeLogger.jl`, avec une sortie à la fois sur la console et dans un fichier.

-   **Communauté & Contribution**
    -   Développement open-source, axé sur la communauté avec des directives de contribution claires et des points d'extension modulaires pour de nouveaux agents, DEX et analyses.

**Diagramme d'Architecture :**

```mermaid
flowchart TD
    subgraph "Logique Utilisateur & SDKs (User Logic & SDKs)"
        TS[Logique Agent/Essaim TypeScript (TypeScript Agent/Swarm Logic)] --> TS_SDK[SDK TS]
        Py[Logique Agent/Essaim Python (Python Agent/Swarm Logic)] --> Py_SDK[Wrapper/SDK Python (Python Wrapper/SDK)]
    end

    subgraph "Backend CutePanel (CutePanel Backend)"
        API[Couche API Julia (Julia API Layer)]
        Core[Moteur Principal Julia (Julia Core Engine)]
        Rust[Signataire Rust Sécurisé (Secure Rust Signer)]
    end

    subgraph "Intégrations DEX (DEX Integrations)"
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


🧑‍🤝‍🧑 Communauté & Contribution
CutePanel est un projet open-source, et nous accueillons les contributions de la communauté ! Que vous soyez développeur, chercheur ou passionné par les technologies décentralisées, l'IA et la blockchain, il existe de nombreuses façons de s'impliquer.

Rejoignez Notre Communauté
Le principal centre de la communauté CutePanel est notre dépôt GitHub :

Dépôt GitHub : https://github.com/KatriaDopex/CutePanel
Problèmes (Issues) : Signalez des bugs, demandez des fonctionnalités ou discutez de défis techniques spécifiques.
Discussions : (Envisagez d'activer les Discussions GitHub) Pour des questions plus larges, des idées et des conversations communautaires.
Pull Requests : Contribuez au code, à la documentation et aux améliorations.
Façons de Contribuer
Nous apprécions toutes les formes de contributions, y compris, mais sans s'y limiter :

💻 Contributions de Code :
Implémenter de nouvelles fonctionnalités pour les agents, les essaims ou les capacités des réseaux neuronaux.
Ajouter la prise en charge de nouvelles blockchains ou de nouveaux ponts.
Améliorer le code existant, les performances ou la sécurité.
Rédiger des tests unitaires et d'intégration.
Développer de nouveaux cas d'utilisation ou des applications exemples.
📖 Documentation :
Améliorer la documentation existante pour plus de clarté et d'exhaustivité.
Rédiger de nouveaux tutoriels ou guides.
Ajouter des exemples à la référence API.
Traduire la documentation.
🐞 Rapports de Bugs & Tests :
Identifier et signaler les bugs avec des étapes de reproduction claires.
Aider à tester les nouvelles versions et fonctionnalités.
💡 Idées & Feedback :
Suggérer de nouvelles fonctionnalités ou améliorations.
Fournir des commentaires sur l'orientation et la convivialité du projet.
📣 Évangélisation & Plaidoyer :
Faire connaître CutePanel.
Rédiger des articles de blog ou créer des vidéos sur vos expériences avec CutePanel.
Démarrer avec les Contributions
Configurez Votre Environnement : Suivez le Démarrage Rapide
Trouvez un Problème : Parcourez la page des Problèmes GitHub. Recherchez les problèmes étiquetés good first issue (bon premier problème) ou help wanted (aide recherchée) si vous êtes nouveau.
Discutez de Vos Plans : Pour de nouvelles fonctionnalités ou des changements importants, il est judicieux d'ouvrir d'abord un problème pour discuter de vos idées avec les mainteneurs et la communauté.
Flux de Travail de Contribution :
Faites un "fork" du dépôt CutePanel sur votre propre compte GitHub.
Créez une nouvelle branche pour vos modifications (par exemple, git checkout -b feature/my-new-feature ou fix/bug-description).
Apportez vos modifications, en respectant les éventuelles directives de style de codage (à définir, voir ci-dessous).
Rédigez ou mettez à jour les tests pour vos modifications.
Validez ("commit") vos modifications avec des messages de commit clairs et descriptifs.
Poussez ("push") votre branche vers votre "fork" sur GitHub.
Ouvrez une Pull Request (PR) par rapport à la branche main ou à la branche de développement appropriée du dépôt KatriaDopex/CutePanel.
Décrivez clairement les modifications dans votre PR et liez-la à tout problème pertinent.
Soyez réactif aux commentaires et participez au processus de révision.
Directives de Contribution
Nous sommes en train de formaliser nos directives de contribution. En attendant, veuillez viser à :

Code Clair : Écrivez du code lisible et maintenable. Ajoutez des commentaires si nécessaire.
Tests : Incluez des tests pour les nouvelles fonctionnalités et les corrections de bugs.
Messages de Commit : Rédigez des messages de commit clairs et concis (par exemple, en suivant les Conventional Commits).
Nous prévoyons de créer prochainement un fichier CONTRIBUTING.md avec des directives détaillées.

Code de Conduite
Nous nous engageons à favoriser une communauté ouverte, accueillante et inclusive. Tous les contributeurs et participants sont tenus de respecter un Code de Conduite. Nous prévoyons d'adopter et de publier un fichier CODE_OF_CONDUCT.md (par exemple, basé sur le Contributor Covenant) dans un proche avenir.
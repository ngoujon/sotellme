# SoTellMe

App menu-bar macOS pour dicter du texte au clavier via F5, avec transcription
100% locale (aucune donnée envoyée à un serveur). Optimisée pour comprendre le
vocabulaire informatique et gaming.

## Comment ça marche

- **F5** démarre l'écoute (un indicateur discret apparaît en haut de l'écran).
- Un second appui sur **F5** arrête l'écoute et lance la transcription.
- Le texte transcrit est automatiquement collé (Cmd+V) dans l'application active.
- Tout tourne en local via [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  (Whisper en CoreML, accéléré par le Neural Engine sur Apple Silicon).

## Build

```bash
./build_app.sh
```

Génère `dist/SoTellMe.app` (build release + bundle + signature ad-hoc).

## Installation

1. Copie `dist/SoTellMe.app` dans `/Applications` (optionnel mais recommandé).
2. Ouvre l'app une première fois via **clic droit > Ouvrir** (elle n'est pas
   notarisée par Apple, donc un double-clic simple sera bloqué par Gatekeeper
   la première fois).
3. macOS va demander deux permissions — accepte les deux :
   - **Microphone** (pour écouter ta voix)
   - **Accessibilité** (Réglages Système > Confidentialité et sécurité >
     Accessibilité — nécessaire pour coller le texte automatiquement)
4. **Important** : va dans Réglages Système > Clavier > Raccourcis clavier >
   Dictée, et désactive (ou change) le raccourci système lié à F5. Sinon la
   Dictée d'Apple se déclenchera en même temps que SoTellMe quand tu appuies
   sur F5.
5. Au premier lancement, l'app télécharge le modèle Whisper (~500 Mo-1 Go,
   une seule fois, puis tout fonctionne hors-ligne).

## Lancement automatique au démarrage (optionnel)

Si tu veux que SoTellMe démarre automatiquement à la connexion :

```bash
cp dist/SoTellMe.app /Applications/
cp LaunchAgent/com.ngoujon.sotellme.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.ngoujon.sotellme.plist
```

Pour désactiver :

```bash
launchctl unload ~/Library/LaunchAgents/com.ngoujon.sotellme.plist
rm ~/Library/LaunchAgents/com.ngoujon.sotellme.plist
```

## Vocabulaire technique / gaming

Deux mécanismes améliorent la reconnaissance du jargon :

1. Un prompt de biais (liste de termes tech/gaming) est injecté au modèle
   avant chaque transcription (`Sources/SoTellMe/Transcriber.swift`).
2. Un dictionnaire de corrections post-transcription
   (`Sources/SoTellMe/Resources/vocab_corrections.json`) corrige les erreurs
   classiques ("git hub" → "GitHub", etc.). Tu peux l'éditer et relancer
   `./build_app.sh` pour ajouter tes propres termes.

## Modèle Whisper

Par défaut : `small` (multilingue FR/EN). Pour réduire la charge CPU/mémoire
sur ta machine, tu peux passer à `base` en éditant l'appel
`transcriber.loadModel(named:)` dans `AppDelegate.swift`.

## Structure du projet

```
Sources/SoTellMe/
  main.swift              Point d'entrée, app menu-bar (pas d'icône Dock)
  AppDelegate.swift        Orchestration (état, statusItem)
  HotkeyManager.swift       Capture globale de F5 (Carbon)
  AudioRecorder.swift       Capture micro → PCM 16kHz mono
  Transcriber.swift         Wrapper WhisperKit + biais vocabulaire
  VocabCorrector.swift      Corrections post-transcription
  ListeningIndicator.swift  HUD flottant discret
  TextInserter.swift        Collage du texte (presse-papiers + Cmd+V)
  Resources/vocab_corrections.json
build_app.sh               Compile + assemble + signe l'app
LaunchAgent/                Plist pour lancement auto (optionnel)
```

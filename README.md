# SoTellMe

App menu-bar macOS pour dicter du texte au clavier via la touche **Globe (🌐)**,
avec transcription 100% locale (aucune donnée envoyée à un serveur). Optimisée
pour comprendre le vocabulaire informatique et gaming.

## Comment ça marche

- Un tap sur **🌐** démarre l'écoute (un indicateur discret apparaît en haut de
  l'écran).
- Un second tap sur **🌐** arrête l'écoute et lance la transcription.
- Le texte transcrit est automatiquement collé (Cmd+V) dans l'application active.
- Tout tourne en local via [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  (Whisper en CoreML, accéléré par le Neural Engine sur Apple Silicon).

> La touche Globe n'a pas d'événement clavier standard (c'est une touche
> modificatrice) : elle est capturée via une surveillance globale des
> événements clavier (`NSEvent`), qui nécessite la permission **Surveillance
> des entrées** (voir ci-dessous). Un tap = appui puis relâchement rapide sans
> appuyer sur une autre touche entre les deux (sinon c'est traité comme un
> raccourci Fn+quelque chose et ignoré).

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
3. macOS va demander plusieurs permissions — accepte-les toutes :
   - **Microphone** (pour écouter ta voix)
   - **Accessibilité** (Réglages Système > Confidentialité et sécurité >
     Accessibilité — nécessaire pour coller le texte automatiquement)
   - **Surveillance des entrées** (Réglages Système > Confidentialité et
     sécurité > Surveillance des entrées — nécessaire pour détecter le tap
     sur la touche Globe). Si la popup n'apparaît pas automatiquement,
     ajoute `SoTellMe.app` toi-même dans cette liste et coche-la, puis
     relance l'app.
4. **Important** : va dans Réglages Système > Clavier, et repère le réglage
   *"Appuyer sur la touche 🌐 pour :"* — mets-le sur **"Ne rien faire"**.
   Sinon macOS ouvrira le sélecteur d'emojis (ou la Dictée, selon la version)
   en même temps que SoTellMe à chaque tap.
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
  HotkeyManager.swift       Capture globale du tap sur la touche Globe (NSEvent)
  AudioRecorder.swift       Capture micro → PCM 16kHz mono
  Transcriber.swift         Wrapper WhisperKit + biais vocabulaire
  VocabCorrector.swift      Corrections post-transcription
  ListeningIndicator.swift  HUD flottant discret
  TextInserter.swift        Collage du texte (presse-papiers + Cmd+V)
  Resources/vocab_corrections.json
build_app.sh               Compile + assemble + signe l'app
LaunchAgent/                Plist pour lancement auto (optionnel)
```
